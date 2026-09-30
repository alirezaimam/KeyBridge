#define main clipboard_cli_main
#include "../src/main.mm"
#undef main
#include "../menubar/Daemon.hpp"
#include <cassert>
#import <objc/runtime.h>
static NSString* fixture;
static int reads;
@interface TestPasteboard : NSObject
- (NSString*)stringForType:(NSString*)type;
@end
@implementation TestPasteboard
- (NSString*)stringForType:(NSString*)type { ++reads; return fixture; }
@end
static id fake_board(id, SEL) { static id board = [TestPasteboard new]; return board; }
int main() {
  std::vector<unsigned char> all;
  for (unsigned c = 32; c <= 126; ++c) {
    all.push_back(c);
    auto k = map_ascii(c);
    assert(k.usage != 0);
    for (unsigned other = 32; other < c; ++other) {
      auto o = map_ascii(other);
      assert(k.usage != o.usage || k.shift != o.shift);
    }
  }
  assert(valid_text(all, 95));
  assert(!valid_text(all, 94));
  assert(!valid_text({}, 256));
  for (unsigned c = 0; c <= 255; ++c) {
    assert(valid_text({static_cast<unsigned char>(c)}, 256) == (c >= 32 && c <= 126));
  }
  const std::string sample = "Hello-VMware_123!@#";
  const uint8_t expected[] = {11,8,15,15,18,45,25,16,26,4,21,8,45,30,31,32,30,31,32};
  const std::string shifts = "1000001100001000111";
  for (size_t i=0; i<sample.size(); ++i) {
    auto k=map_ascii(sample[i]);
    assert(k.usage==expected[i]); assert(k.shift==(shifts[i]=='1'));
  }
  assert(map_ascii(' ').usage == 44);
  assert(map_ascii('~').usage == 53 && map_ascii('~').shift);
  assert(map_ascii('"').usage == 52 && map_ascii('"').shift);
  assert(map_ascii('|').usage == 49 && map_ascii('|').shift);
  Method method = class_getClassMethod([NSPasteboard class], @selector(generalPasteboard));
  IMP original = method_setImplementation(method, reinterpret_cast<IMP>(fake_board));
  for (NSString* value in @[@"Hello-VMware_123!@#", @"", @"a\n", @"a\t", @"a\r", @"é", @"😀"]) {
    fixture = value; reads = 0;
    clipboard_buffer buffer;
    bool result = read_clipboard(buffer, 256);
    assert(reads == 1);
    assert(result == [value isEqualToString:@"Hello-VMware_123!@#"]);
  }
  fixture = @"abcd";
  { clipboard_buffer buffer; assert(!read_clipboard(buffer, 3)); }
  { clipboard_buffer buffer; assert(read_clipboard(buffer, 4)); }
  method_setImplementation(method, original);
  unsigned number;
  assert(parse_unsigned("256", number) && number == 256);
  assert(!parse_unsigned("-1", number));
  assert(!parse_unsigned("12x", number));
  assert(!parse_unsigned("", number));
  assert(!parse_unsigned(nullptr, number));
  int sockets[2];
  assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
  hotkey_state state{sockets[0], 256};
  auto event = CGEventCreateKeyboardEvent(nullptr, 9, true);
  CGEventSetFlags(event, kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate);
  assert(hotkey_event(nullptr, kCGEventKeyDown, event, &state) == nullptr);
  assert(!state.busy && !state.pending); // No typing before the helper is ready.
  assert(command(sockets[1], 'R'));
  hotkey_tick(nullptr, &state);
  assert(state.hid_ready);
  assert(hotkey_event(nullptr, kCGEventKeyDown, event, &state) == nullptr);
  assert(state.busy && state.pending && state.swallow_v);
  auto first_deadline = state.deadline;
  assert(hotkey_event(nullptr, kCGEventKeyDown, event, &state) == nullptr);
  assert(state.deadline == first_deadline); // Busy requests are not queued.
  assert(hotkey_event(nullptr, kCGEventKeyUp, event, &state) == nullptr);
  assert(!state.swallow_v);
  state.busy = state.pending = false;
  state.shortcut_key = 7; // X
  state.shortcut_modifiers = kCGEventFlagMaskControl;
  CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, 7);
  CGEventSetFlags(event, kCGEventFlagMaskControl);
  assert(hotkey_event(nullptr, kCGEventKeyDown, event, &state) == nullptr);
  assert(state.busy && state.pending); // Saved shortcut replaces the default.
  state.busy = state.pending = false;
  CGEventSetFlags(event, kCGEventFlagMaskCommand);
  assert(hotkey_event(nullptr, kCGEventKeyDown, event, &state) == event);
  CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, 53);
  CGEventSetFlags(event, 0);
  CGEventSetIntegerValueField(event, kCGKeyboardEventKeycode, 53);
  assert(hotkey_event(nullptr, kCGEventKeyDown, event, &state) == event); // Idle Escape passes through.
  assert(!state.busy && !state.pending);
  assert(hotkey_event(nullptr, kCGEventKeyUp, event, &state) == event);
  state.busy = state.sent = true;
  assert(hotkey_event(nullptr, kCGEventKeyDown, event, &state) == nullptr);
  char c = 0;
  assert(transfer(sockets[1], &c, 1, false) && c == 'C');
  assert(state.busy && state.cancel_sent); // Remains busy until helper acknowledges.
  cancel_job(state);
  assert(recv(sockets[1], &c, 1, MSG_DONTWAIT) < 0 && errno == EAGAIN);
  assert(command(sockets[1], 'C'));
  hotkey_tick(nullptr, &state);
  assert(!state.busy && !state.sent);
  state.busy = state.sent = true;
  hotkey_event(nullptr, kCGEventTapDisabledByTimeout, event, &state);
  assert(state.quit && state.cancel_sent);
  assert(transfer(sockets[1], &c, 1, false) && c == 'C');
  for (const auto& error : {std::pair{'B', "Another Clipboard HID session is active"},
                            std::pair{'H', "Virtual HID is unavailable"},
                            std::pair{'P', "Helper rejected this app connection"}}) {
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    hotkey_state error_state{sockets[0], 256};
    error_state.shutdown_handler = [] {};
    assert(command(sockets[1], error.first));
    hotkey_tick(nullptr, &error_state);
    assert(error_state.quit && std::string_view(error_state.message) == error.second);
    close(sockets[0]); close(sockets[1]);
  }
  CFRelease(event);
  close(sockets[0]); close(sockets[1]);

  // Interrupt a long hold promptly without sending any HID reports.
  std::atomic<bool> failed(false);
  cancelled = false;
  cancellation_probe = [] { return true; };
  auto before = std::chrono::steady_clock::now();
  assert(!pause_ms(60000, failed));
  assert(std::chrono::steady_clock::now() - before < std::chrono::milliseconds(100));
  cancellation_probe = {}; cancelled = false;

  // Root helper rejects malformed framing and invalid text before touching HID.
  for (uint32_t size : {0u, 257u, 1u}) {
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    assert(command(sockets[1], 'T'));
    assert(transfer(sockets[1], &size, sizeof(size), true));
    if (size == 1) assert(command(sockets[1], '\n'));
    assert(helper_loop(sockets[0], options{}) == 1);
    close(sockets[0]); close(sockets[1]);
  }
  assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
  close(sockets[1]);
  assert(!transfer(sockets[0], &c, 1, false));
  close(sockets[0]);
  struct fake_client {
    int reports = 0;
    void async_post_report(const virtual_hid_device_driver::hid_report::keyboard_input&) { ++reports; }
  };
  struct fake_connection {
    std::atomic<bool> failed{false};
    std::unique_ptr<fake_client> client = std::make_unique<fake_client>();
    bool wait_ready() { return !failed && !stop_requested(); }
  } warm;
  clipboard_buffer tiny;
  tiny.bytes = {'a'};
  options fast;
  fast.start_delay_ms = 0; fast.key_down_ms = fast.key_up_ms = 1;
  auto* identity = warm.client.get();
  assert(type_buffer(tiny, fast, warm) == 0);
  assert(type_buffer(tiny, fast, warm) == 0);
  assert(warm.client.get() == identity && warm.client->reports == 10);
  cancellation_probe = [] { return true; };
  assert(type_buffer(tiny, fast, warm) == 3);
  assert(warm.client->reports == 11); // Cancellation before priming only sends release.
  cancellation_probe = {};
  assert(type_buffer(tiny, fast, warm) == 0); // Same connection works after cancel.
  assert(warm.client.get() == identity && warm.client->reports == 16);
  const uint32_t good_settings[] = {256,40,40,0};
  assert(valid_settings(good_settings));
  uint32_t bad_settings[] = {0,40,40,0};
  assert(!valid_settings(bad_settings));
  bad_settings[0] = 256; bad_settings[1] = 0;
  assert(!valid_settings(bad_settings));
  bad_settings[1] = 40; bad_settings[3] = 60001;
  assert(!valid_settings(bad_settings));
  assert(daemon_main("invalid-hash") == 2); // Never creates a service/socket.
  assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
  assert(helper_loop(sockets[0], options{}, nullptr, [] { return false; }) == 1);
  uid_t peer;
  assert(!trusted_peer(sockets[0], "0000000000000000000000000000000000000000", peer));
  if (desktop_user(getuid())) {
    SecCodeRef self_code = nullptr;
    CFDictionaryRef info = nullptr;
    assert(SecCodeCopySelf(kSecCSDefaultFlags, &self_code) == errSecSuccess);
    assert(SecCodeCopySigningInformation(self_code, kSecCSSigningInformation, &info) == errSecSuccess);
    NSData* unique = [(__bridge NSDictionary*)info objectForKey:(__bridge NSString*)kSecCodeInfoUnique];
    assert(unique.length == 20);
    NSMutableString* own_hash = [NSMutableString string];
    for (NSUInteger i=0;i<unique.length;++i) [own_hash appendFormat:@"%02x", static_cast<const unsigned char*>(unique.bytes)[i]];
    assert(trusted_peer(sockets[0], own_hash.UTF8String, peer));
    CFRelease(info); CFRelease(self_code);
  }
  close(sockets[0]); close(sockets[1]);
  std::cout << "PASS: daemon bounds, peer rejection and inactive-session guard; persistent connection reuse, readiness gate, cancel/reuse; hotkey suppression, busy exclusion, Escape, tap failure, protocol bounds, cancellation; 95 unique ASCII mappings, byte validation, length limits, PoC mapping.\n";
}
