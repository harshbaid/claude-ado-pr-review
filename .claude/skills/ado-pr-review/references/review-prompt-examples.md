# The review prompt - your #1 customization point

The prompt in `review-pr.md` Step 3 is what actually decides what gets flagged. Everything else in
this bot is plumbing; this is the brain. Spend your tuning effort here.

## The shipped template (neutral)

```
You are a senior reviewer for a <DESCRIBE YOUR STACK: languages, frameworks, runtime, platform>. Report ONLY issues in these categories: (1) Bugs — incorrect logic, wrong function calls, broken type invariants (2) Security — leaked secrets, token exposure, injection/XSS (3) Runtime performance — sequential awaits that should be parallel, missing lazy-loading for heavy modules, unbounded loops over API data (4) Data integrity — silent data loss, incorrect filters, wrong entity mappings. Skip: style, naming, formatting, minor type casts that do not cause runtime errors, things that are correct, accessibility unless broken. For each issue output exactly: **[CATEGORY]** file path + line context, the problem in one sentence, the fix in one sentence or a short code block. If no issues found, say so in one line. Do not summarize the PR, do not explain what the code does, do not list things that look good.
```

## A worked example (Next.js + Sitecore headless on Vercel)

This is a real prompt driving this bot in production. Notice it does two things the template leaves
to you: it names a **specific stack** (so the model reasons about the right failure modes), and it
keeps the **exact same four categories** (which held up well across thousands of PRs).

```
You are a senior reviewer for a Next.js 15 Pages Router / React 19 / TypeScript / Tailwind CSS v4 / headless-CMS project on Vercel. Report ONLY issues in these categories: (1) Bugs — incorrect logic, wrong function calls, broken type invariants (2) Security — leaked secrets, token exposure, XSS (3) Runtime performance — sequential awaits that should be parallel, missing dynamic imports for heavy modules, unbounded loops over API data (4) Data integrity — silent data loss, incorrect filters, wrong entity mappings. Skip: style, naming, formatting, minor type casts that do not cause runtime errors, things that are correct, accessibility unless broken. For each issue output exactly: **[CATEGORY]** file path + line context, the problem in one sentence, the fix in one sentence or a short code block. If no issues found, say so in one line. Do not summarize the PR, do not explain what the code does, do not list things that look good.
```

## Why the prompt is shaped this way (tuning guidance)

- **Name your stack concretely.** "senior reviewer for a Go microservice using sqlc + pgx on GKE"
  makes the model reason about the *right* footguns (context cancellation, connection pool exhaustion)
  instead of generic advice.
- **Fewer, sharper categories beat many vague ones.** Bugs / Security / Performance / Data-integrity
  is a deliberately narrow net. It keeps signal high and comment volume low. Add a category only when
  you find yourself repeatedly wishing the bot had caught a *class* of issue.
- **Explicitly list what to SKIP.** Style, naming, formatting, "looks good" narration - these are the
  noise that makes teams mute a bot. The skip list matters as much as the report list.
- **Force a rigid output shape.** `**[CATEGORY]** file:line / problem / fix` parses reliably in Step 4
  and reads well in the ADO thread UI. If you change the shape, update the Step 4 parser to match.
- **Ban PR summaries.** "Do not summarize the PR / do not list things that look good" stops the model
  burning output on prose no reviewer reads.

## The pre-verification step is what makes it trustworthy

A raw prompt like this produces both "this is broken" and "you might want to check X" findings. The
"check X" ones are where false positives live. `review-pr.md` Step 5.5 takes each finding and tries to
*prove or disprove it against the PR's actual source tree* (`git grep`/`git show` at `$headSha`)
before posting - dropping the ones it can disprove and upgrading the ones it confirms with concrete
evidence. That verification pass is the difference between a bot developers trust and one they mute.
Keep it. Extend it with stack-specific recipes in `verification-recipes.md`.
