#import <AppKit/AppKit.h>
#include <algorithm>
#include <filesystem>
#include <atomic>
#include <charconv>
#include <chrono>
#include <csignal>
#include <iostream>
#include <string_view>
#include <thread>
#include <vector>
#include <unistd.h>
#include <functional>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <pqrs/karabiner/driverkit/virtual_hid_device_driver.hpp>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>

namespace {
using namespace pqrs::karabiner::driverkit;
volatile std::sig_atomic_t interrupted = 0;
void on_signal(int value) { interrupted = value; }
struct options {
  unsigned max_length = 256, key_down_ms = 40, key_up_ms = 40,
           inter_key_ms = 0, start_delay_ms = 5000;
};
struct hid_key { uint8_t usage; bool shift; };

hid_key map_ascii(unsigned char c) {
  if (c >= 'a' && c <= 'z') return {static_cast<uint8_t>(4 + c - 'a'), false};
  if (c >= 'A' && c <= 'Z') return {static_cast<uint8_t>(4 + c - 'A'), true};
  // USB HID usages for the US ANSI number and punctuation keys.
  constexpr std::string_view unshifted = "1234567890-=[]\\;',./`";
  constexpr std::string_view shifted   = "!@#$%^&*()_+{}|:\"<>?~";
  constexpr uint8_t usages[] = {30,31,32,33,34,35,36,37,38,39,45,46,47,48,49,51,52,54,55,56,53};
  if (c == ' ') return {44, false};
  auto i = unshifted.find(c);
  if (i != std::string_view::npos) return {usages[i], false};
  i = shifted.find(c);
  if (i != std::string_view::npos) return {usages[i], true};
  return {0, false};
}

bool valid_text(const std::vector<unsigned char>& text, unsigned max_length) {
  if (text.empty() || text.size() > max_length) return false;
  for (auto c : text) if (c < 0x20 || c > 0x7e) return false;
  return true;
}

struct clipboard_buffer {
  std::vector<unsigned char> bytes;
  ~clipboard_buffer() {
    volatile unsigned char* p = bytes.data();
    for (size_t i = 0; i < bytes.size(); ++i) p[i] = 0;
  }
};

bool read_clipboard(clipboard_buffer& buffer, unsigned max_length) {
  @autoreleasepool {
    // One content read; never re-read the pasteboard during typing.
    NSString* text = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
    if (!text || text.length == 0 || text.length > max_length) return false;
    buffer.bytes.resize(text.length);
    for (NSUInteger i = 0; i < text.length; ++i) {
      unichar c = [text characterAtIndex:i];
      if (c < 0x20 || c > 0x7e) return false;
      buffer.bytes[i] = static_cast<unsigned char>(c);
    }
  }
  return valid_text(buffer.bytes, max_length);
}

std::function<bool()> cancellation_probe;
bool cancelled = false;
bool stop_requested() {
  if (cancellation_probe && cancellation_probe()) cancelled = true;
  return interrupted || cancelled;
}

bool pause_ms(unsigned ms, const std::atomic<bool>& failed) {
  auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
  while (!stop_requested() && !failed) {
    auto now = std::chrono::steady_clock::now();
    if (now >= end) return true;
    std::this_thread::sleep_for(std::min(end - now,
        std::chrono::steady_clock::duration(std::chrono::milliseconds(10))));
  }
  return false;
}

void usage() {
  std::cout << "Usage: virtual-hid-device-service-client [options]\n"
    "  --max-length N       Maximum ASCII characters (default 256, max 1048576)\n"
    "  --key-down-ms N      Hold each key (default 40, range 1..60000)\n"
    "  --key-up-ms N        Released-key wait (default 40, range 1..60000)\n"
    "  --inter-key-ms N     Extra wait between characters (default 0, max 60000)\n"
    "  --start-delay-ms N   Initial wait (CLI 5000, hotkey 0; max 60000)\n"
    "  --hotkey-session     Listen for Option-Command-V; Escape cancels (sudo once)\n"
    "  --help               Show help without reading clipboard\n"
    "Only nonempty printable ASCII is accepted. Enter, Tab and newlines are rejected.\n";
}

// One dispatcher/client lifetime per one-shot invocation or entire hotkey session.
struct hid_connection {
  std::atomic<bool> ready{false}, failed{false};
  std::unique_ptr<virtual_hid_device_service::client> client;
  hid_connection() {
    pqrs::dispatcher::extra::initialize_shared_dispatcher();
    client = std::make_unique<virtual_hid_device_service::client>();
    client->connected.connect([this] {
      virtual_hid_device_service::virtual_hid_keyboard_parameters parameters;
      parameters.set_country_code(pqrs::hid::country_code::us);
      client->async_virtual_hid_keyboard_initialize(parameters);
    });
    client->connect_failed.connect([this](auto&&) { failed = true; });
    client->error_occurred.connect([this](auto&&) { failed = true; });
    client->closed.connect([this] { failed = true; });
    client->driver_version_mismatched.connect([this](bool mismatch) { if (mismatch) failed = true; });
    client->virtual_hid_keyboard_ready.connect([this](bool value) {
      if (!value && ready) failed = true;
      ready = value;
    });
    client->async_start();
  }
  ~hid_connection() {
    client->async_post_report(virtual_hid_device_driver::hid_report::keyboard_input{});
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    client.reset();
    pqrs::dispatcher::extra::terminate_shared_dispatcher();
  }
  bool wait_ready() {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!ready && !failed && !stop_requested() && std::chrono::steady_clock::now() < deadline)
      pause_ms(10, failed);
    if (!ready && !stop_requested()) failed = true;
    return ready && !failed && !stop_requested();
  }
};

template <typename Connection>
int type_buffer(const clipboard_buffer& buffer, const options& opt, Connection& connection) {
  cancelled = false;
  auto& client = *connection.client;
  auto& failed = connection.failed;
  {
    if (connection.wait_ready()) {
      if (!cancellation_probe) std::cout << "Virtual keyboard ready. Focus target; typing starts in "
                << opt.start_delay_ms << " ms.\n" << std::flush;
      if (pause_ms(opt.start_delay_ms, failed)) {
        // Some remote-console clients, including Windows guests, only start
        // consuming a virtual keyboard after a state-changing report. Prime the
        // path with a harmless Shift press and release before clipboard text.
        virtual_hid_device_driver::hid_report::keyboard_input prime;
        prime.modifiers.insert(virtual_hid_device_driver::hid_report::modifier::left_shift);
        client.async_post_report(prime);
        if (!pause_ms(25, failed)) {
          client.async_post_report(virtual_hid_device_driver::hid_report::keyboard_input{});
          return failed ? 1 : 3;
        }
        client.async_post_report(virtual_hid_device_driver::hid_report::keyboard_input{});
        if (!pause_ms(100, failed)) {
          client.async_post_report(virtual_hid_device_driver::hid_report::keyboard_input{});
          return failed ? 1 : 3;
        }
        for (size_t i = 0; i < buffer.bytes.size() && !failed && !stop_requested(); ++i) {
          auto key = map_ascii(buffer.bytes[i]);
          virtual_hid_device_driver::hid_report::keyboard_input report;
          if (key.shift) report.modifiers.insert(virtual_hid_device_driver::hid_report::modifier::left_shift);
          report.keys.insert(key.usage);
          client.async_post_report(report);
          pause_ms(opt.key_down_ms, failed);
          client.async_post_report(virtual_hid_device_driver::hid_report::keyboard_input{});
          if (!pause_ms(opt.key_up_ms, failed)) break;
          if (i + 1 < buffer.bytes.size() && !pause_ms(opt.inter_key_ms, failed)) break;
        }
      }
    }
    // Best-effort release and drain: this API has no delivery acknowledgement.
    client.async_post_report(virtual_hid_device_driver::hid_report::keyboard_input{});
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
  }
  if (interrupted) { std::cerr << "Interrupted; keys released where possible.\n"; return 128 + interrupted; }
  if (cancelled) return 3;
  if (failed) { std::cerr << "Virtual HID unavailable, disconnected, or timed out.\n"; return 1; }
  std::cout << "Typing reports sent.\n";
  return 0;
}
int type_buffer(const clipboard_buffer& buffer, const options& opt) {
  hid_connection connection;
  return type_buffer(buffer, opt, connection);
}
} // namespace

#include "hotkey.hpp"

int main(int argc, char** argv) {
  std::signal(SIGINT, on_signal);
  std::signal(SIGTERM, on_signal);
  std::signal(SIGHUP, on_signal);
  std::signal(SIGPIPE, SIG_IGN);
  if (argc == 4 && std::string_view(argv[1]) == "--hotkey-agent")
    return hotkey_agent_entry(argv[2], argv[3]);
  options opt;
  bool hotkeys = false, explicit_delay = false;
  for (int i = 1; i < argc; ++i) {
    std::string_view name(argv[i]);
    if (name == "--hotkey-session") { hotkeys = true; continue; }
    if (name == "--start-delay-ms") explicit_delay = true;
    if (name == "--help") { usage(); return 0; }
    unsigned* field = nullptr;
    unsigned minimum = 0, maximum = 60000;
    if (name == "--max-length") { field = &opt.max_length; minimum = 1; maximum = 1048576; }
    else if (name == "--key-down-ms") { field = &opt.key_down_ms; minimum = 1; }
    else if (name == "--key-up-ms") { field = &opt.key_up_ms; minimum = 1; }
    else if (name == "--inter-key-ms") field = &opt.inter_key_ms;
    else if (name == "--start-delay-ms") field = &opt.start_delay_ms;
    if (!field || ++i == argc) { std::cerr << "Invalid option or missing value. Use --help.\n"; return 2; }
    std::string_view value(argv[i]);
    auto result = std::from_chars(value.data(), value.data() + value.size(), *field);
    if (result.ec != std::errc{} || result.ptr != value.data() + value.size() ||
        *field < minimum || *field > maximum) {
      std::cerr << "Invalid numeric option. Use --help.\n"; return 2;
    }
  }
  if (geteuid() != 0) { std::cerr << "Run with sudo to connect to the Virtual HID service.\n"; return 1; }
  // One instance across the session listener and one-shot CLI invocations.
  int lock_fd = open("/var/run/clipboard-virtual-hid.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
  struct stat lock_info{};
  if (lock_fd < 0 || fstat(lock_fd, &lock_info) || !S_ISREG(lock_info.st_mode) ||
      lock_info.st_uid != 0 || flock(lock_fd, LOCK_EX | LOCK_NB)) {
    if (lock_fd >= 0) close(lock_fd);
    std::cerr << "Another instance is running, or the instance lock is unavailable.\n";
    return 1;
  }
  if (hotkeys) {
    if (!explicit_delay) opt.start_delay_ms = 0;
    return hotkey_session(opt, lock_fd);
  }
  clipboard_buffer buffer;
  if (!read_clipboard(buffer, opt.max_length)) {
    std::cerr << "Clipboard rejected: requires nonempty printable ASCII within max length.\n";
    return 2;
  }
  return type_buffer(buffer, opt);
}
