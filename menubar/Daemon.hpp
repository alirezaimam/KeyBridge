#pragma once
#import <Security/Security.h>
#include "Protocol.hpp"
#include <mach/message.h>

namespace {

bool desktop_user(uid_t uid) {
  struct stat info{};
  return uid != 0 && stat("/dev/console", &info) == 0 && info.st_uid == uid;
}
bool trusted_peer(int fd, const char* hash, uid_t& uid) {
  gid_t gid;
  if (getpeereid(fd, &uid, &gid) || !desktop_user(uid)) return false;
  audit_token_t token{};
  socklen_t size = sizeof(token);
  if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) || size != sizeof(token)) return false;
  NSData* audit = [NSData dataWithBytes:&token length:sizeof(token)];
  NSDictionary* attributes = @{(__bridge NSString*)kSecGuestAttributeAudit: audit};
  SecCodeRef code = nullptr;
  SecRequirementRef requirement = nullptr;
  NSString* rule = [NSString stringWithFormat:@"cdhash H\"%s\"", hash];
  bool valid = SecCodeCopyGuestWithAttributes(nullptr, (__bridge CFDictionaryRef)attributes,
                                             kSecCSDefaultFlags, &code) == errSecSuccess &&
               SecRequirementCreateWithString((__bridge CFStringRef)rule, kSecCSDefaultFlags, &requirement) == errSecSuccess &&
               SecCodeCheckValidity(code, kSecCSStrictValidate, requirement) == errSecSuccess;
  if (requirement) CFRelease(requirement);
  if (code) CFRelease(code);
  return valid;
}
int daemon_main(const char* hash) {
  if (geteuid() != 0 || strlen(hash) != 40 || strspn(hash, "0123456789abcdef") != 40) return 2;
  umask(0077);
  if (mkdir("/var/run/local.clipboardhid", 0755) && errno != EEXIST) return 1;
  struct stat directory{};
  if (lstat("/var/run/local.clipboardhid", &directory) || !S_ISDIR(directory.st_mode) ||
      directory.st_uid != 0 || (directory.st_mode & 0022)) return 1;
  chmod("/var/run/local.clipboardhid", 0755);
  int listener = socket(AF_UNIX, SOCK_STREAM, 0);
  if (listener < 0) return 1;
  sockaddr_un address{}; address.sun_family = AF_UNIX;
  strlcpy(address.sun_path, helper_socket, sizeof(address.sun_path));
  unlink(helper_socket);
  if (bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) ||
      chmod(helper_socket, 0666) || listen(listener, 4)) { close(listener); return 1; }
  while (!interrupted) {
    pollfd descriptor{listener, POLLIN, 0};
    if (poll(&descriptor, 1, 100) <= 0) continue;
    int fd = accept(listener, nullptr, nullptr);
    if (fd < 0) continue;
    @autoreleasepool {
      uid_t uid;
      uint32_t values[4]{};
      if (!trusted_peer(fd, hash, uid) || !transfer(fd, values, sizeof(values), false) || !valid_settings(values)) {
        command(fd, 'P');
        close(fd); continue;
      }
      int lock = open("/var/run/clipboard-virtual-hid.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
      struct stat lock_info{};
      if (lock < 0 || fstat(lock, &lock_info) || !S_ISREG(lock_info.st_mode) || lock_info.st_uid != 0 ||
          flock(lock, LOCK_EX | LOCK_NB)) {
        command(fd, 'B');
        if (lock >= 0) close(lock);
        close(fd); continue;
      }
      options opt; opt.max_length = values[0]; opt.key_down_ms = values[1];
      opt.key_up_ms = values[2]; opt.inter_key_ms = values[3]; opt.start_delay_ms = 0;
      cancelled = false;
      {
        hid_connection connection;
        if (connection.wait_ready() && desktop_user(uid) && command(fd, 'R'))
          helper_loop(fd, opt, &connection, [uid] { return desktop_user(uid); });
        else
          command(fd, 'H');
      }
      close(lock);
      shutdown(fd, SHUT_RDWR); close(fd);
    }
  }
  close(listener); unlink(helper_socket);
  return 0;
}
}
