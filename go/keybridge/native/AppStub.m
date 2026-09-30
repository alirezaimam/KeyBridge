// Xcode builds this tiny executable only to assemble KeyBridge.app resources,
// assets, and the embedded privileged helper. build.sh replaces it with the
// Go menu-bar executable before signing the final bundle.
int main(void) { return 0; }
