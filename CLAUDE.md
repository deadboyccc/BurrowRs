@AGENTS.md

## Claude Code notes

- Everything in AGENTS.md applies. These are additions for working in Claude Code.
- **Tokens:** if the maintainer hands you a GitHub token for a push, use it only through a
  one-off credential helper that reads a 0600 temp file, and delete the file afterwards.
  Never write a token into the repo, git config or memory, and remind the maintainer to
  rotate it.
- **Before every push:** `make lint test-unit`, then re-read the diff for claims you haven't
  verified. After the push, check the CI run, and fix it if it's red.
- **Tight hosts:** build images with `docker build --memory`, and remove throwaway images
  and stacks when you're done. Disk and RAM on dev and CI machines are not free.
- **Never run a real proxy on a shared host.** Use `./burrowrs try` or the test stacks
  (127.0.0.1 only), and take them down afterwards.
- **Reports:** brief and concrete. Say what changed, what was verified and how, and what
  still needs a human, such as rotating a credential.
