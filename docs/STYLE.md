# Code, script, comment and doc style

How code, scripts, comments and docs are written in this repo, so everything reads like one person wrote it,
whether that's me or an agent. It's ported from the style guides in two of my other projects: the code and comment
style from Above Your Rank (`docs/STYLE.md` there), and the writing voice and security writing rules from my
website (`VOICE.md` there). The C#-specific parts are swapped out for the languages a fuzzing setup actually uses:
C and C++ for harnesses, Python for orchestration and triage, Bash for Linux boxes and containers, and PowerShell
for Windows.

When in doubt, copy the style of the code around you.

---

## Comments are the documentation

My comments do more work than most people's. The code says *what* happens; the comments say *why* it happens,
what something is for, what its numbers mean, and how it fits with the rest of the setup. A new reader (or an
agent with no context) should be able to understand a file from its comments alone. So:

- **Explain the why, and the reasoning behind the design,** especially anything that looks odd, any trade-off
  made on purpose, and anything chosen "for now".
- **Every file, type, field and function gets a comment.** Short is fine when the thing is simple.
- **The logic inside a function is walked through in numbered step comments,** thoroughly enough that someone
  could follow the function from its comments alone (see [Functions](#functions)).
- **Plain line comments only.** `//` in C and C++, `#` in Python, Bash and PowerShell. No Doxygen blocks
  (`/** @brief ... @param ... */`) and no docstring scaffolding (`Args:`, `Returns:`, `:param x:`). Those exist
  to generate docs for libraries other people consume. Every reader here has the source, and the scaffolding
  adds lines that compete with the code for attention. The one exception is a PowerShell script's opening
  `<# ... #>` block, which holds its banner (see [Scripts](#scripts)).

---

## The voice in comments

Comments use the same voice as my writing, a notch cleaner: plain English, practical, honest about trade-offs,
and grounded in specifics.

- **Write full sentences in plain words.** "How long one input may run before we call it a hang, in
  milliseconds." Not "Exec timeout (ms)."
- **"We" is the project, and sometimes the object itself.** "We fork a fresh server per input so one crash can't
  poison the next run." Use "I" and "my" only in personal notes and writeups, never in code.
- **Be honest about deferred and imperfect decisions.** "For now", "good enough for a first pass", and "we can
  revisit this later" are fine, as long as the reason is there too.
- **Be specific.** Name the real thing: the function, the file, the unit, the number, the fuzzer flag, the
  upstream function a harness calls into. "In bytes", "per second", "in milliseconds", "from 0 to 1".
- **Point at related code** with `(see corpus.py)` or `(see CSteamNetworkConnectionBase::ProcessPlainTextDataChunk)`.
- **Use my usual shorthand:** "e.g.", "i.e.", parentheses for asides, and lists that trail off end with "etc..."
  (three dots).
- **Explain the current design, not its history.** "This used to be..." or "the old version did..." belongs in
  the commit message, not the comment.
- **Hedge opinions, not facts.** "I think" belongs to judgement calls. If something was measured or reproduced,
  say what was measured and how, plainly.

**Don't:**
- **No em dashes (—). Ever.** Use a comma, a colon, a period or parentheses instead. This applies to comments,
  docs and commit messages alike.
- No hype words: "robust", "seamless", "leverage", "powerful", "elegant", "game-changer", "supercharge",
  "cutting-edge", "unlock".
- No LLM-isms: "delve", "it's worth noting", "note that", "crucially", "a testament to".
- No "It's not just X, it's Y", and no reflexive groups of three adjectives.
- No jokes or "lol" in code comments. Save those for blog posts.
- Don't narrate what the code obviously does (`// increment i`). Say why it's done, or say nothing.
- No commented-out code. Delete it; git remembers.

---

## File layout

Every file starts with a banner, the file name centred between two `====` rules that run to column 120 (copy one
from an existing file rather than counting), followed by an overview of what the file is for:

```cpp
// =====================================================================================================================
//                                                gns-message-harness.cpp
// =====================================================================================================================
// A libFuzzer harness for GameNetworkingSockets' plain text data chunk parser: feeds each input to a connection
// as if it had just arrived off the wire, after the handshake, so the fuzzer spends its time on message framing
// rather than on getting past crypto it can't forge.
//
// ----- Why we skip the handshake -----
// Longer explanations get their own subsections, titled like this one.
#include "steam/steamnetworkingsockets.h"
```

- **The overview says what the file is, why it exists, and how it fits** with the rest of the setup. Longer
  explanations get `----- Title -----` subsections.
- **A script's overview also says how to run it,** on its own indented line, and what it needs (tools,
  network access, a display, root, etc...). See [Scripts](#scripts).
- **One main thing per file,** named after it. Small helpers that only exist to serve it can live at the bottom
  of the same file, separated by four blank lines.
- **Lines are at most 120 characters,** in code and in Markdown alike.

---

## Sections and spacing

Inside a file or type, group members into sections with a divider padded with `=` to about the same width as the
banner (again, copy an existing one):

```python
# ========== Settings ==================================================================================================
```

- **Three blank lines before a section divider,** one after.
- **Two blank lines between functions.**
- **One blank line between fields,** unless they're grouped under one comment.
- **Common section names:** Settings, State, Public API, then one section per area of behaviour.

---

## Fields, constants and settings

Every field, constant and setting gets a comment above it saying what it holds, its units or range, and anything
non-obvious about why it's set up that way:

```python
# How long one input may run before we call it a hang, in milliseconds. Well above the ~2 ms a normal message
# takes, so a slow machine doesn't drown the triage queue in false hangs, but low enough that a real infinite
# loop is caught in the same minute.
HANG_TIMEOUT_MILLISECONDS = 1000

# The biggest input we hand the target, in bytes. A little over GameNetworkingSockets' own per-message limit, so
# the fuzzer can still try lengths the parser is supposed to refuse.
MAX_INPUT_BYTES = 600 * 1024
```

- **Closely related fields can share one comment.**
- **Put units in the name** when they'd otherwise be ambiguous (`HANG_TIMEOUT_MILLISECONDS`,
  `executions_per_second`, `max_input_bytes`).

---

## Functions

A comment says what the function does, what it returns, and, when it's not obvious, who calls it and when. In C
and C++ it goes above the function; in Python and Bash it's the first lines inside the body (that's how my
scripts already do it). Inside, the logic is walked through in numbered steps, and each step comment says what
that step does and why. Be generous with them: reading only the step comments, top to bottom, should tell a new
reader (or an agent with no context) what the function does, in what order, and why each part is there.

```python
def minimize_corpus(corpus_directory, output_directory):
    # Shrinks a campaign's corpus to the smallest set of inputs that still hits every edge, so a restart or a
    # new campaign doesn't waste its first hours replaying duplicates. Returns how many inputs were kept.
    # 1: Nothing to do for an empty corpus, and afl-cmin fails loudly on one.
    if not any(corpus_directory.iterdir()):
        return 0
    # 2: Minimize into a fresh folder, so an interrupted run never leaves a half-written corpus behind.
    output_directory.mkdir(parents=True, exist_ok=False)
    run(["afl-cmin", "-i", corpus_directory, "-o", output_directory, "--", HARNESS])
    # 3: Count what's left, for the campaign log.
    return sum(1 for _ in output_directory.iterdir())
```

- **Number steps `1:`, `2:`,** and sub-steps `2.1:`, `2.2:`. Only one- or two-line functions go without step
  comments.
- **Lean towards more steps, not fewer.** Give a step to each distinct thing the function does, not just its two
  or three big phases: each guard worth a reason, each branch, each loop, and each line whose purpose isn't
  obvious at a glance. A step can cover a few lines when they do one thing together.
- **Say what the step is for, not what the syntax does.** "2.1: Skip inputs smaller than the header, the parser
  refuses those before it reads anything" helps; "loop over the inputs" doesn't.
- **No blank lines between steps;** the numbered comments already separate them.
- **Guard clauses first, as one-line early returns,** and `continue` early in loops.
- **"Public API."** at the start of a function's comment marks one meant to be called from other modules, when
  that's worth calling out.
- **Keep functions small enough that their steps fit on one screen.** When one grows past that, the steps
  usually want to be their own functions.

---

## Naming

- **Use full words, not abbreviations** (`crash_directory`, not `crash_dir`; `executions_per_second`, not
  `eps`), except well-known ones (`id`, `url`, `x`/`y`) and the names fuzzing tools use themselves (`afl-cmin`,
  `ASAN_OPTIONS`, `LLVMFuzzerTestOneInput`). This goes for folder and file names too
  (`scripts/setup/setup-fuzzer.sh`, not `infra/` or `setup-fuzz.sh`). The only short folder names are the ones
  nearly every repository uses and tools expect: `src`, `docs`, `tests`, `bin`, `build`.
- **Files and folders are lowercase with hyphens** (`triage-crashes.py`, `gns-message-harness.cpp`), except
  Python modules that get imported, which use underscores because Python requires it (`crash_triage.py`).
- **Booleans read as yes/no questions:** `is_reproducible`, `has_new_coverage`, `IsConnected`.
- **Functions are verbs:** `minimize_corpus`, `ReplayInput`, `parse_sanitizer_report`.
- **Test names are plain-English sentences:** `test_a_duplicate_crash_is_bucketed_with_the_first`,
  `EmptyInputDoesNothing`.
- **Each language keeps its own casing:**
  - **Python:** `snake_case` for functions, variables and modules, `PascalCase` for classes, `UPPER_CASE` for
    constants (PEP 8).
  - **Bash:** `snake_case` for variables and functions; `UPPER_CASE` only for environment variables.
  - **PowerShell:** `Verb-Noun` functions with approved verbs, `$camelCase` variables.
  - **C and C++ (our own code):** `PascalCase` for types and functions, `camelCase` for locals and parameters,
    `_camelCase` for private members, `UPPER_CASE` for macros. Same as my C# so it reads the same.
- **Code that patches or extends a target follows the target's style, not ours.** A patch to
  GameNetworkingSockets uses Valve's names (`m_nFoo`, `CSteamNetworkConnectionBase`) and their comment style, so
  it applies cleanly and reads like the code around it. Our harness code that calls into it uses ours.

---

## Language habits

### Python

- **`pathlib` for paths, f-strings for formatting,** and the standard library first.
- **Find files from the script's own location** (`pathlib.Path(__file__).resolve().parent`), never from the
  current directory, so a script works no matter where it's run from.
- **Pin dependencies exactly** in one place (`requirements.txt` or `pyproject.toml`), never floating (`>=`, `~=`).
  A campaign has to be reproducible months later.
- **A `main()` function and an `if __name__ == "__main__":` guard** in anything runnable.

### Bash

- **Start with `#!/usr/bin/env bash` and `set -euo pipefail`.**
- **Quote every expansion** (`"$crash_directory"`), and use `[[ ]]` and `$(...)`.
- **Find the repo root from the script's location:**
  `repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"`.

### PowerShell

- **Start with `#Requires -Version 7.0`, `$ErrorActionPreference = 'Stop'` and `Set-StrictMode -Version Latest`.**
- **Except bootstrap scripts that run on a fresh Windows,** which only has Windows PowerShell 5.1: those use
  `#Requires -Version 5.1` and `Set-StrictMode -Version 2.0`, no PowerShell 7 syntax (`??`, ternaries, `&&`), and
  plain ASCII only, since 5.1 reads a file without a byte order mark in the ANSI code page.
- **Check native commands' exit codes,** since `Stop` doesn't cover them; use a small `Invoke-Native` helper that
  throws on a nonzero `$LASTEXITCODE`.
- **Find the repo root from `$PSScriptRoot`.**

### C and C++

- **`#pragma once`** in headers.
- **Compiler warnings are errors** in our own code (`-Wall -Wextra -Werror`), not in the target's.
- **Keep harnesses thin:** turn the input into a call into the target, and nothing more. Setup that's the same
  for every input goes in `LLVMFuzzerInitialize` or a one-time static, with a comment saying why it's safe to
  share.

### Everywhere

- **`todo:`** (lowercase) for known gaps, with enough detail that someone else could pick it up.
- **Pin every version that affects results:** compilers, fuzzers, sanitizers, container base images, and the
  target's commit. If it's not pinned, a crash found today might not reproduce next month.

---

## Scripts

Scripts get the same banner, overview and numbered steps as code. The overview says what the script does, how to
run it (on its own indented line), and what it needs. In Bash the numbered steps are comments; in PowerShell,
bigger phases can use `# ---- 1: Name ----...` section rules instead.

```bash
#!/usr/bin/env bash
# ======================================================================================================================
#                                                     setup-fuzzer.sh
# ======================================================================================================================
# Installs AFL++ and the LLVM toolchain we build harnesses with, into a fresh Linux box or container. Safe to run
# repeatedly; it does nothing that's already done.
#
#   bash scripts/setup/setup-fuzzer.sh
#
# Needs root and network access to apt.llvm.org and github.com.
set -euo pipefail
```

- **Safe to re-run.** A setup script checks before it changes anything, and says when something's already done.
- **Say what's happening** with one `==> ` line per step (`echo "==> Building the harness"`), so a log shows
  where a run got to.
- **Fail clearly.** When a tool is missing, say which one and where the docs explain getting it.
- **Run from the repo root** (e.g. `bash scripts/setup/setup-fuzzer.sh`); each script finds the root from its own
  location.
- **`scripts/README.md` lists every script** with a one-line "what it's for". Update it in the same change as
  the script.

---

## Docs

- **Docs (Markdown) use the same voice,** with plain, descriptive headings and short paragraphs. Bold the lead
  phrase of a list item when the list is a set of named points (like this one).
- **Each main folder has a short `README.md`** saying what's in it and where to start. Full explanations live in
  `docs/`; a README orients and links there.
- **Commands are copy-pasteable,** in fenced code blocks with a language tag, with tool versions noted where they
  matter.
- **Research is kept as dated decision records:** what was decided, the alternatives rejected and why, and the
  evidence, with sources. That way a settled question isn't reopened without the evidence that settled it.
- **Never invent results.** No made-up numbers, crashes, coverage or timings. If something hasn't been measured
  yet, leave a `todo:` saying what to measure.
- **Do the math in the sentence** when numbers make the point: "about 900 execs/sec, so roughly 29 million inputs
  over 9 hours."

### Crash and campaign writeups

Starting points, not forms to fill in. Drop sections that don't apply.

**A campaign log** (one per campaign):
1. **Target.** Repository, commit, the entry point being fuzzed, and why this one.
2. **Setup.** Fuzzer and version, compiler and sanitizers, flags, seed corpus and dictionary.
3. **Results.** Real numbers: runtime, execs/sec, edges covered, crashes and unique buckets.
4. **Dead ends.** What didn't work. I keep these in; they're honest and useful.
5. **What I'd do next.**

**A crash triage note** (one per unique bug):
1. **Summary.** Where it crashes, the bug class (CWE), and the sanitizer's verdict, in one or two lines.
2. **Reproduce.** The exact command and the input's file name and hash.
3. **Root cause.** The code or design flaw, explained so a developer could avoid it.
4. **Impact.** What an attacker could realistically do, without exaggerating. "An unauthenticated peer can crash
   the server with one packet" beats "critical remote vulnerability".
5. **Status.** Reported to whom and when, and whether it's fixed.

### Security rules (non-negotiable)

- **Only public targets and personal research,** done on my own time and equipment. Nothing from work, in any
  form.
- **Crashes stay private until they're fixed.** Reproducing inputs, triage notes and anything else that points at
  an unpatched bug never go in a public repo, issue, commit message or writeup until coordinated disclosure is
  done (the vendor has fixed it or the agreed deadline has passed). For Valve that means their bug bounty program.
- **Redact** secrets, tokens, internal hostnames, real IPs and personal data in logs and output.
- **Be precise about impact.** Don't hype a bug, and don't hedge one I've proven.

---

## Commit messages

- **Start with a short summary in the imperative** ("Add a corpus minimizer for AFL++ campaigns"), then a body
  saying what changed and why, wrapped at about 90 characters.
- **Same voice, same rules:** no em dashes, no hype words, real numbers when there are some.
- **Never name an unpatched bug's details** in a commit message (see the security rules above).

---

## Checklist

- [ ] Does every file have a banner and an overview, and every type, field and function a comment?
- [ ] Do the comments explain why, not just what?
- [ ] Are function steps numbered (`1:`), thoroughly enough to follow each function from its step comments alone,
  with no blank lines between them?
- [ ] Are sections divided with `========== Name ===...` and spaced three lines apart?
- [ ] Plain line comments only (no Doxygen, no docstring scaffolding), and zero em dashes?
- [ ] None of the hype words or LLM-isms?
- [ ] Units in names or comments wherever a number could be ambiguous?
- [ ] Lines at most 120 characters?
- [ ] Names spelled out in full, in code and in folder and file names?
- [ ] Every version that affects results pinned?
- [ ] Nothing about an unpatched bug anywhere public?
