/* LPI Essentials — Study Drill
 *
 * Drill loop:
 *   answer right -> question leaves the bank for good (until you Reset)
 *   answer wrong -> correct answer is shown immediately, question stays in the bank
 */

const STORAGE_KEY = 'lpi-essentials-study-drill/v1';

/* ---------------------------------------------------------------- state */

const blankState = () => ({
  mastered: [],   // question ids retired from the bank
  missed:   {},   // id -> times missed
  answered: 0,
  correct:  0,
  streak:   0,
  best:     0,
});

let state = loadState();
let current = null;   // { q, options, picked:Set<number>, graded:bool }
let lastId  = null;   // avoid showing the same question twice in a row

function loadState() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return blankState();
    return Object.assign(blankState(), JSON.parse(raw));
  } catch {
    return blankState();
  }
}

function saveState() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch {
    /* storage disabled — the session still works, it just isn't persisted */
  }
}

/* ---------------------------------------------------------------- helpers */

const $ = id => document.getElementById(id);

function shuffle(arr) {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

const masteredSet = () => new Set(state.mastered);
const remaining   = () => QUESTION_BANK.filter(q => !masteredSet().has(q.id));

function escapeHtml(s) {
  return s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

/* ---------------------------------------------------------------- chrome */

function renderStats() {
  const total = QUESTION_BANK.length;
  const done  = state.mastered.length;

  $('statMastered').textContent  = done;
  $('statRemaining').textContent = total - done;
  $('statStreak').textContent    = state.streak;
  $('statAccuracy').textContent  = state.answered
    ? Math.round((state.correct / state.answered) * 100) + '%'
    : '—';

  $('progressFill').style.width = (done / total) * 100 + '%';
}

/* ---------------------------------------------------------------- question */

function nextQuestion() {
  const pool = remaining();

  if (pool.length === 0) {
    showDone();
    return;
  }

  // Don't repeat the question we just did unless it's the only one left.
  let choices = pool.length > 1 ? pool.filter(q => q.id !== lastId) : pool;
  if (choices.length === 0) choices = pool;

  const q = choices[Math.floor(Math.random() * choices.length)];
  lastId = q.id;

  current = {
    q,
    options: shuffle(q.options),
    picked: new Set(),
    graded: false,
  };

  renderQuestion();
}

function renderQuestion() {
  const { q, options } = current;
  const multi = q.answer.length > 1;

  $('quizView').hidden = false;
  $('doneView').hidden = true;

  $('qTag').textContent  = remaining().length + ' left in the bank';
  $('qHint').textContent = multi ? 'Select ' + q.answer.length : 'Select one';
  $('qText').textContent = q.question;

  const form = $('options');
  form.className = 'options';
  form.innerHTML = '';

  options.forEach((text, i) => {
    const label = document.createElement('label');
    label.className = 'opt';

    const input = document.createElement('input');
    input.type = multi ? 'checkbox' : 'radio';
    input.name = 'opt';
    input.value = String(i);

    const num = document.createElement('span');
    num.className = 'num';
    const numInner = document.createElement('span');
    numInner.textContent = String(i + 1);
    num.appendChild(numInner);

    const body = document.createElement('span');
    body.textContent = text;

    label.append(input, num, body);
    label.addEventListener('click', e => {
      e.preventDefault();
      pick(i);
    });

    form.appendChild(label);
  });

  $('feedback').hidden = true;
  $('btnSubmit').hidden = false;
  $('btnSubmit').disabled = true;
  $('btnNext').hidden = true;

  renderStats();
}

function pick(index) {
  if (!current || current.graded) return;

  const multi = current.q.answer.length > 1;
  if (multi) {
    if (current.picked.has(index)) current.picked.delete(index);
    else current.picked.add(index);
  } else {
    current.picked = new Set([index]);
  }

  document.querySelectorAll('#options .opt').forEach((el, i) => {
    el.classList.toggle('picked', current.picked.has(i));
  });

  $('btnSubmit').disabled = current.picked.size === 0;
}

/* ---------------------------------------------------------------- grading */

function grade() {
  if (!current || current.graded || current.picked.size === 0) return;

  const { q, options, picked } = current;
  const answers = new Set(q.answer);
  const chosen  = [...picked].map(i => options[i]);
  const isRight = chosen.length === q.answer.length && chosen.every(t => answers.has(t));

  current.graded = true;

  // Mark every option: correct ones green, wrong picks red.
  const form = $('options');
  form.classList.add('graded');
  form.querySelectorAll('.opt').forEach((el, i) => {
    if (answers.has(options[i])) el.classList.add('correct');
    else if (picked.has(i))      el.classList.add('wrong');
  });

  // Update the bank.
  state.answered++;
  if (isRight) {
    state.correct++;
    state.streak++;
    state.best = Math.max(state.best, state.streak);
    if (!masteredSet().has(q.id)) state.mastered.push(q.id);
  } else {
    state.streak = 0;
    state.missed[q.id] = (state.missed[q.id] || 0) + 1;
  }
  saveState();

  const fb = $('feedback');
  fb.hidden = false;
  fb.className = 'feedback ' + (isRight ? 'right' : 'wrong');

  if (isRight) {
    fb.innerHTML =
      '<b>Correct.</b>' +
      '<span class="sub">Retired from the bank — you will not see it again until you reset.</span>';
  } else {
    const list = q.answer.map(a => '"' + escapeHtml(a) + '"').join(' and ');
    fb.innerHTML =
      '<b>Not quite. Correct answer: ' + list + '</b>' +
      '<span class="sub">Back into the bank — it will come around again.</span>';
  }

  $('btnSubmit').hidden = true;
  $('btnNext').hidden = false;
  $('btnNext').focus();

  renderStats();
}

/* ---------------------------------------------------------------- done */

function showDone() {
  current = null;
  $('quizView').hidden = true;
  $('doneView').hidden = false;

  const acc = state.answered ? Math.round((state.correct / state.answered) * 100) : 100;
  $('doneSummary').textContent =
    'All ' + QUESTION_BANK.length + ' questions answered correctly. ' +
    state.answered + ' answers given, ' + acc + '% accuracy, best streak ' + state.best + '.';

  renderStats();
}

/* ---------------------------------------------------------------- reset */

function reset() {
  if (!confirm('Clear all progress? Every question goes back into the bank.')) return;
  state = blankState();
  lastId = null;
  saveState();
  closeStats();
  nextQuestion();
}

/* ---------------------------------------------------------------- progress panel */

function openStats() {
  const total = QUESTION_BANK.length;
  $('pMastered').textContent  = state.mastered.length;
  $('pRemaining').textContent = total - state.mastered.length;
  $('pAnswered').textContent  = state.answered;
  $('pBest').textContent      = state.best;

  const list = $('troubleList');
  list.innerHTML = '';

  const rows = Object.entries(state.missed)
    .map(([id, n]) => ({ q: QUESTION_BANK.find(x => x.id === Number(id)), n }))
    .filter(r => r.q)
    .sort((a, b) => b.n - a.n);

  if (rows.length === 0) {
    const li = document.createElement('li');
    li.className = 'clean';
    li.textContent = 'Nothing missed yet.';
    list.appendChild(li);
  } else {
    const done = masteredSet();
    rows.forEach(({ q, n }) => {
      const li = document.createElement('li');
      li.innerHTML =
        escapeHtml(q.question) +
        '<span class="miss">missed ' + n + '&times;' +
        (done.has(q.id) ? ' &middot; now mastered' : '') + '</span>';
      list.appendChild(li);
    });
  }

  $('statsOverlay').hidden = false;
}

function closeStats() {
  $('statsOverlay').hidden = true;
}

/* ---------------------------------------------------------------- export / import */

function exportProgress() {
  const blob = new Blob([JSON.stringify(state, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'lpi-study-progress.json';
  a.click();
  URL.revokeObjectURL(url);
}

function importProgress(file) {
  const reader = new FileReader();
  reader.onload = () => {
    try {
      const data = JSON.parse(reader.result);
      if (!Array.isArray(data.mastered)) throw new Error('bad file');
      state = Object.assign(blankState(), data);
      saveState();
      closeStats();
      nextQuestion();
    } catch {
      alert('That file does not look like an exported progress file.');
    }
  };
  reader.readAsText(file);
}

/* ---------------------------------------------------------------- wiring */

$('btnSubmit').addEventListener('click', grade);
$('btnNext').addEventListener('click', nextQuestion);
$('btnReset').addEventListener('click', reset);
$('btnResetDone').addEventListener('click', reset);
$('btnStats').addEventListener('click', openStats);
$('btnCloseStats').addEventListener('click', closeStats);
$('statsOverlay').addEventListener('click', e => {
  if (e.target.id === 'statsOverlay') closeStats();
});
$('btnExport').addEventListener('click', exportProgress);
$('btnImport').addEventListener('click', () => $('fileImport').click());
$('fileImport').addEventListener('change', e => {
  if (e.target.files[0]) importProgress(e.target.files[0]);
  e.target.value = '';
});

document.addEventListener('keydown', e => {
  if (!$('statsOverlay').hidden) {
    if (e.key === 'Escape') closeStats();
    return;
  }

  if (e.key === 'Enter') {
    e.preventDefault();
    if (!$('doneView').hidden) return;
    if (current && current.graded) nextQuestion();
    else grade();
    return;
  }

  const n = Number(e.key);
  if (n >= 1 && n <= 9 && current && !current.graded) {
    e.preventDefault();
    if (n <= current.options.length) pick(n - 1);
  }
});

/* ---------------------------------------------------------------- boot */

renderStats();
nextQuestion();
