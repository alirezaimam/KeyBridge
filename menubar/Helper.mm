#define main clipboard_cli_main
#include "../src/main.mm"
#undef main
#include "Daemon.hpp"
int main(int argc, char** argv) {
  std::signal(SIGINT,on_signal); std::signal(SIGTERM,on_signal); std::signal(SIGHUP,on_signal); std::signal(SIGPIPE,SIG_IGN);
  if (argc == 3 && std::string_view(argv[1]) == "--helper") return daemon_main(argv[2]);
  return 2;
}
