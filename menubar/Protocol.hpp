#pragma once
#include <sys/un.h>
namespace {
constexpr const char* helper_socket = "/var/run/local.clipboardhid/control.sock";
bool valid_settings(const uint32_t* values) {
  return values[0] >= 1 && values[0] <= 1048576 &&
         values[1] >= 1 && values[1] <= 60000 &&
         values[2] >= 1 && values[2] <= 60000 && values[3] <= 60000;
}
}
