# LPI Essentials — Study Drill

A local, single-question-at-a-time drill over the LPI Linux Essentials question bank.

## How to run

Double-click **`start.cmd`** (or just open `index.html` in a browser). No install, no build, no
network. Everything runs from these files.

If your browser refuses to keep progress on a `file://` page, run **`serve.cmd`** instead — it
serves the folder on `http://127.0.0.1:8777` using the Python already on your machine.

## Using it on your phone (GitHub Pages)

The app is fully static, so GitHub Pages serves it with no build step and no Actions workflow.

```bash
gh repo create lpi-study-drill --public --source=. --remote=origin --push
gh api -X POST repos/:owner/lpi-study-drill/pages -f "source[branch]=main" -f "source[path]=/"
```

It goes live at `https://<your-username>.github.io/lpi-study-drill/` about a minute later.

Every path in the app is relative, so it works under a repo subpath without any config. If you
ever rename the repo, nothing inside needs changing.

### Add to Home Screen

Open the Pages URL on your phone, then:

- **iOS Safari** — Share → *Add to Home Screen*
- **Android Chrome** — ⋮ menu → *Add to Home screen* / *Install app*

`manifest.json` sets `display: standalone`, so it launches without browser chrome and looks like a
native app. The keyboard legend hides itself on touch devices, tap targets are sized for thumbs,
and the layout respects the iOS notch and home indicator.

### Progress is per-device

`localStorage` is scoped to one browser on one device, so your phone and desktop each keep their
own bank. Drilling on your phone will not shrink the bank on your laptop.

To move a session across, use **Export progress** on one device and **Import progress** on the
other.

Two storage caveats worth knowing:

- Clearing browser data or using private/incognito mode wipes progress.
- On iOS, a site kept only in Safari (not added to the Home Screen) can have its storage evicted
  after about a week of not opening it. Adding it to the Home Screen avoids this.

## How the drill works

- You get one random question from the bank.
- **Right answer** → the question is retired. It never comes back until you hit **Reset**.
- **Wrong answer** → the correct answer is highlighted immediately, and the question goes back
  into the bank to be asked again later.
- The bank shrinks only as you get things right, so a session ends when you've answered all 80
  correctly at least once.

A question is never asked twice in a row (unless it's the last one left).

## Controls

| Key | Action |
| --- | --- |
| `1`–`9` | Select an option (toggles, on multi-answer questions) |
| `Enter` | Check answer, then again to advance |
| `Esc` | Close the progress panel |

Multi-answer questions show a **Select 2** hint and use checkboxes; grading requires the exact set.

## Progress

Progress lives in your browser's `localStorage` under `lpi-essentials-study-drill/v1`.

The **Progress** button opens a panel with mastered/remaining counts, total answers, best streak,
and a **trouble spots** list — every question you've missed, most-missed first. That list survives
mastering a question, so you can still see what kept tripping you up.

**Export progress** writes `lpi-study-progress.json`; **Import progress** loads it back. Use these
to move a session between browsers or machines, or as a backup before clearing browser data.

**Reset** puts all 80 questions back in the bank and zeroes every counter.

## Editing the question bank

`questions.js` holds the bank as a plain array:

```js
const QUESTION_BANK = [
  {
    "id": 81,
    "question": "Which command ...?",
    "options": ["a", "b", "c", "d"],
    "answer": ["b"]
  }
];
```

Rules: `id` must be unique (progress is keyed on it), and every string in `answer` must match an
`options` string exactly. More than one entry in `answer` makes it a multi-select question.

Questions and options are both shuffled every time a question is presented, so answer order is
never a memorizable cue.

## Credit

The 80-question bank comes from [ThePrimoris/LPI-Essentials-Practice](https://github.com/ThePrimoris/LPI-Essentials-Practice)
(the site at <https://theprimoris.github.io/LPI-Essentials-Practice/>). The original is a
fixed-length practice exam — 40 or 80 questions, answer them all, then submit and get a score.
This rebuild replaces that with the repeat-until-mastered loop above; the question data is
unmodified.

## Files

| File | What it is |
| --- | --- |
| `index.html` | Page structure |
| `style.css` | Styling (follows your OS light/dark setting) |
| `app.js` | Drill logic, grading, progress |
| `questions.js` | The question bank |
| `start.cmd` | Opens the app in your default browser |
| `serve.cmd` | Fallback: serves on localhost:8777 |
| `manifest.json` | Add-to-Home-Screen config |
| `icon-192.png` / `icon-512.png` | App icons |
