#pragma once
#import <ApplicationServices/ApplicationServices.h>
#include <cerrno>
#include <cstdlib>
#include <grp.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <pwd.h>
#include <sys/socket.h>
#include <sys/wait.h>

namespace {
// Private inherited socket only: no named socket, daemon, or passwordless sudo rule.
bool transfer(int fd, void* data, size_t size, bool sending) {
  auto* p = static_cast<unsigned char*>(data);
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (size && !interrupted && std::chrono::steady_clock::now() < deadline) {
    pollfd descriptor{fd, static_cast<short>(sending ? POLLOUT : POLLIN), 0};
    int result = poll(&descriptor, 1, 20);
    if (result < 0 && errno == EINTR) continue;
    if (result < 0 || (descriptor.revents & (POLLERR | POLLNVAL))) return false;
    if (!result) continue;
    auto count = sending ? send(fd, p, size, MSG_DONTWAIT) : recv(fd, p, size, MSG_DONTWAIT);
    if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
    if (count <= 0) return false;
    p += count;
    size -= count;
  }
  return size == 0;
}
bool command(int fd, char value) { return transfer(fd, &value, 1, true); }
bool parse_unsigned(const char* value, unsigned& number) {
  if (!value) return false;
  std::string_view text(value);
  auto r = std::from_chars(text.data(), text.data() + text.size(), number);
  return !text.empty() && r.ec == std::errc{} && r.ptr == text.data() + text.size();
}

struct hotkey_state {
  int fd;
  unsigned max_length;
  CGKeyCode shortcut_key = 9; // V
  CGEventFlags shortcut_modifiers = kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate;
  bool hid_ready = false;
  bool enabled = true;
  const char* message = "Preparing virtual keyboard...";
  std::function<void()> shutdown_handler;
  bool busy = false, pending = false, sent = false, cancel_sent = false;
  bool swallow_v = false, swallow_escape = false, quit = false;
  std::unique_ptr<clipboard_buffer> snapshot;
  std::chrono::steady_clock::time_point deadline{}, released_since{};
};

void cancel_job(hotkey_state& state) {
  state.pending = false;
  state.snapshot.reset();
  if (state.sent) {
    if (!state.cancel_sent && !command(state.fd, 'C')) state.quit = true;
    state.cancel_sent = true;
  } else {
    state.busy = false;
  }
}

CGEventRef hotkey_event(CGEventTapProxy, CGEventType type, CGEventRef event, void* context) {
  auto& state = *static_cast<hotkey_state*>(context);
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    // Losing Escape/release visibility must never leave a job running unattended.
    std::cerr << "Shortcut monitoring was disabled; stopping the session.\n";
    cancel_job(state);
    state.quit = true;
    return event;
  }
  auto key = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
  if (type == kCGEventKeyUp) {
    if (key == 9 && state.swallow_v) { state.swallow_v = false; return nullptr; }
    if (key == 53 && state.swallow_escape) { state.swallow_escape = false; return nullptr; }
  }
  if (type != kCGEventKeyDown) return event;
  if (key == 53 && (state.busy || state.swallow_escape)) {
    state.swallow_escape = true;
    cancel_job(state);
    return nullptr;
  }
  constexpr auto mask = kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate |
                        kCGEventFlagMaskShift | kCGEventFlagMaskControl;
  auto flags = CGEventGetFlags(event);
  if (state.enabled && key == state.shortcut_key &&
      (flags & mask) == state.shortcut_modifiers) {
    state.swallow_v = true;
    if (state.hid_ready && !state.busy && !CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat)) {
      state.busy = state.pending = true;
      state.cancel_sent = false;
      state.released_since = {};
      state.deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    }
    return nullptr;
  }
  return event;
}

bool trigger_released(CGKeyCode) {
  constexpr auto modifiers = kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate |
                             kCGEventFlagMaskShift | kCGEventFlagMaskControl;
  return !(CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) & modifiers);
}

void hotkey_tick(CFRunLoopTimerRef, void* context) {
  auto& state = *static_cast<hotkey_state*>(context);
  if (interrupted) state.quit = true;
  char response;
  auto count = recv(state.fd, &response, 1, MSG_DONTWAIT);
  if (count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)) state.quit = true;
  if (count == 1 && response == 'R' && !state.hid_ready && !state.sent) {
    state.hid_ready = true;
    state.message = "Ready";
    std::cout << "Listening: HID ready. Option-Command-V types clipboard; Escape cancels. Ctrl-C stops session.\n" << std::flush;
  } else if (count == 1) {
    if (!state.sent && response == 'B') {
      state.message = "Another Clipboard HID session is active";
      state.quit = true;
    } else if (!state.sent && response == 'H') {
      state.message = "Virtual HID is unavailable";
      state.quit = true;
    } else if (!state.sent && response == 'P') {
      state.message = "Helper rejected this app connection";
      state.quit = true;
    } else {
      if (!state.sent || (response != 'D' && response != 'C' && response != 'E')) state.quit = true;
      state.busy = state.sent = state.cancel_sent = false;
      state.message = response == 'D' ? "Ready" : response == 'C' ? "Cancelled" : "HID failed";
      std::cout << (response == 'D' ? "Ready.\n" : response == 'C' ? "Cancelled. Ready.\n" : "HID failed.\n") << std::flush;
    }
  }
  if (state.quit) {
    cancel_job(state);
    shutdown(state.fd, SHUT_RDWR);
    if (state.shutdown_handler) state.shutdown_handler();
    else CFRunLoopStop(CFRunLoopGetCurrent());
    return;
  }
  if (!state.pending) return;
  if (!state.snapshot) {
    state.snapshot = std::make_unique<clipboard_buffer>();
    if (!read_clipboard(*state.snapshot, state.max_length)) {
      state.message = "Clipboard rejected: use single-line ASCII within length limit";
      std::cerr << "Clipboard rejected: printable ASCII within max length required.\n";
      cancel_job(state);
      return;
    }
  }
  auto now = std::chrono::steady_clock::now();
  if (now >= state.deadline) {
    state.message = "Cancelled: release the shortcut keys";
    std::cerr << "Cancelled: shortcut keys were not released within five seconds.\n";
    cancel_job(state);
    return;
  }
  if (!trigger_released(state.shortcut_key) ||
      CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, state.shortcut_key)) {
    state.released_since = {}; return;
  }
  if (state.released_since == std::chrono::steady_clock::time_point{}) state.released_since = now;
  if (now - state.released_since < std::chrono::milliseconds(100)) return;
  if (CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) & kCGEventFlagMaskAlphaShift) {
    state.message = "Cancelled: turn Caps Lock off";
    std::cerr << "Cancelled: turn Caps Lock off for US ANSI typing.\n";
    cancel_job(state);
    return;
  }
  uint32_t size = static_cast<uint32_t>(state.snapshot->bytes.size());
  if (!command(state.fd, 'T') || !transfer(state.fd, &size, sizeof(size), true) ||
      !transfer(state.fd, state.snapshot->bytes.data(), size, true)) {
    state.quit = true;
    shutdown(state.fd, SHUT_RDWR);
  } else {
    state.sent = true;
    state.message = "Typing...";
  }
  state.pending = false;
  state.snapshot.reset();
}

int hotkey_agent_entry(const char* fd_text, const char* limit_text) {
  unsigned fd, limit;
  if (geteuid() == 0 || !parse_unsigned(fd_text, fd) || fd > INT_MAX ||
      !parse_unsigned(limit_text, limit) || limit == 0 || limit > 1048576) return 2;
  uid_t peer_uid; gid_t peer_gid;
  if (getpeereid(fd, &peer_uid, &peer_gid) || peer_uid != 0) return 1;
  @autoreleasepool {
    hotkey_state state{static_cast<int>(fd), limit};
    auto events = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    auto tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                               kCGEventTapOptionDefault, events, hotkey_event, &state);
    if (!tap) {
      std::cerr << "Cannot listen for shortcuts. Enable Accessibility for your terminal/the CLI in\n"
                   "System Settings > Privacy & Security; also allow Input Monitoring if requested.\n"
                   "Then restart this command. No keys were sent.\n";
      close(fd);
      return 1;
    }
    auto source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopTimerContext timer_context{0, &state, nullptr, nullptr, nullptr};
    auto timer = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 0.01,
                                     0, 0, hotkey_tick, &timer_context);
    if (!source || !timer) {
      if (source) CFRelease(source);
      if (timer) CFRelease(timer);
      CFRelease(tap); close(fd); return 1;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    std::cout << "Preparing virtual keyboard...\n" << std::flush;
    CFRunLoopRun();
    CFRunLoopTimerInvalidate(timer);
    CFMachPortInvalidate(tap);
    CFRelease(timer); CFRelease(source); CFRelease(tap);
    close(fd);
  }
  return interrupted ? 128 + interrupted : 1;
}

int helper_loop(int fd, const options& opt, hid_connection* connection = nullptr,
                std::function<bool()> session_valid = {}) {
  bool peer_closed = false;
  cancellation_probe = [&] {
    if (session_valid && !session_valid()) { peer_closed = true; return true; }
    char value;
    auto n = recv(fd, &value, 1, MSG_DONTWAIT);
    if (n < 0 && (errno == EAGAIN || errno == EINTR)) return false;
    if (n == 1 && value == 'C') return true;
    peer_closed = true;
    return true;
  };
  int result = 0;
  while (!interrupted && !peer_closed) {
    if (session_valid && !session_valid()) { result = 1; break; }
    if (connection && connection->failed) { result = 1; break; }
    pollfd descriptor{fd, POLLIN, 0};
    int polled = poll(&descriptor, 1, 100);
    if (polled < 0 && errno == EINTR) continue;
    if (polled < 0) { result = 1; break; }
    if (!polled) continue;
    char value;
    if (!transfer(fd, &value, 1, false)) break;
    if (value == 'C') continue; // Cancellation may cross the completion acknowledgement.
    if (value != 'T') { result = 1; break; }
    uint32_t size = 0;
    if (!transfer(fd, &size, sizeof(size), false) || !size || size > opt.max_length) { result = 1; break; }
    clipboard_buffer buffer;
    buffer.bytes.resize(size);
    if (!transfer(fd, buffer.bytes.data(), size, false) || !valid_text(buffer.bytes, opt.max_length)) {
      result = 1; break;
    }
    if (!connection) { result = 1; break; }
    int typed = type_buffer(buffer, opt, *connection);
    if (peer_closed || interrupted) break;
    if (!command(fd, typed == 0 ? 'D' : typed == 3 ? 'C' : 'E')) break;
    if (typed != 0 && typed != 3) { result = 1; break; }
  }
  cancellation_probe = {};
  return interrupted ? 128 + interrupted : result;
}

int hotkey_session(const options& opt, int lock_fd) {
  unsigned uid;
  struct stat console{};
  if (!parse_unsigned(getenv("SUDO_UID"), uid) || uid == 0 ||
      stat("/dev/console", &console) || console.st_uid != uid) {
    std::cerr << "Start with sudo from the logged-in desktop user's terminal.\n";
    return 1;
  }
  auto user = getpwuid(uid);
  if (!user) return 1;
  std::string username(user->pw_name);
  gid_t gid = user->pw_gid;
  char executable[PATH_MAX]; uint32_t capacity = sizeof(executable);
  if (_NSGetExecutablePath(executable, &capacity)) return 1;
  char absolute[PATH_MAX];
  if (!realpath(executable, absolute)) return 1;
  int sockets[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets)) return 1;
  // The listener execs after permanently dropping root, before any AppKit use.
  pid_t child = fork();
  if (child < 0) { close(sockets[0]); close(sockets[1]); return 1; }
  if (child == 0) {
    close(sockets[0]); close(lock_fd);
    if (initgroups(username.c_str(), gid) || setgid(gid) || setuid(uid) || geteuid() != uid) _exit(1);
    std::string descriptor = std::to_string(sockets[1]);
    std::string maximum = std::to_string(opt.max_length);
    execl(absolute, absolute, "--hotkey-agent", descriptor.c_str(), maximum.c_str(), nullptr);
    _exit(1);
  }
  close(sockets[1]);
  int result = 1;
  {
    // Initialize after fork; no dispatcher thread is inherited by the listener.
    hid_connection connection;
    if (connection.wait_ready() && command(sockets[0], 'R'))
      result = helper_loop(sockets[0], opt, &connection);
    else
      std::cerr << "Virtual HID could not become ready.\n";
  }
  shutdown(sockets[0], SHUT_RDWR); close(sockets[0]);
  kill(child, SIGTERM);
  int status = 0;
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  pid_t reaped = 0;
  while ((reaped = waitpid(child, &status, WNOHANG)) == 0 &&
         std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  if (reaped == 0) {
    kill(child, SIGKILL); // Bound shutdown if the GUI process is stuck in a system call.
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
  }
  close(lock_fd);
  return result ? result : (WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 1);
}
} // namespace
