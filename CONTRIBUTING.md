# Contributing to KeyBridge

Thanks for contributing. KeyBridge interacts with the macOS clipboard, global
shortcuts, a privileged helper, and a virtual keyboard, so every change should
be small, reviewable, and manually tested when it changes user-visible typing.

## Before opening a pull request

1. Describe the problem and the expected behavior.
2. Keep clipboard contents out of commits, tests, screenshots, logs, and issue
   text whenever they might contain private data.
3. Run the relevant tests:

   ```sh
   cd go/keybridge
   go test -race ./...
   ```

4. For changes to the native helper or HID behavior, also follow the native
   test instructions in `tests/run.sh` and manually test with a harmless,
   non-sensitive clipboard value.
5. Update documentation when changing settings, permissions, installation, or
   compatibility.

## Pull request expectations

- Explain the behavior before and after the change.
- State exactly which tests you ran.
- Do not include generated app bundles, packages, build caches, credentials, or
  personal clipboard data.
- Do not weaken helper authentication, code-signing checks, or clipboard
  validation without a security review.
- Disclose material generative-AI assistance when it helps reviewers identify
  areas that need independent verification.

## Issues

Use the bug-report or feature-request template. Do not report suspected
security vulnerabilities in public issues; follow the repository security
policy instead.
