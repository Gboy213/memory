// Статуслайн станции: модель · папка · токены контекста · лимиты 5h/7d · цена сессии.
// Запускается Claude Code, JSON приходит на stdin. Написан на node, чтобы не тянуть jq.

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => (raw += d));
process.stdin.on('end', () => {
  let d;
  try {
    d = JSON.parse(raw.replace(/^﻿/, '').trim());
  } catch {
    process.stdout.write('statusline: не разобрал JSON\n');
    return;
  }

  const DIM = '\x1b[2m', RESET = '\x1b[0m';
  const GREEN = '\x1b[32m', YELLOW = '\x1b[33m', RED = '\x1b[31m', CYAN = '\x1b[36m';

  // зелёный / жёлтый / красный по мере заполнения
  const heat = (pct) => (pct >= 80 ? RED : pct >= 50 ? YELLOW : GREEN);

  const tok = (n) => {
    if (n === null || n === undefined) return '?';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000) return Math.round(n / 1000) + 'k';
    return String(n);
  };

  const parts = [];

  // --- модель ---
  const model = d.model && d.model.display_name;
  if (model) parts.push(CYAN + model + RESET);

  // --- папка ---
  const cwd = (d.workspace && d.workspace.current_dir) || d.cwd;
  if (cwd) parts.push(DIM + cwd.replace(/\\/g, '/').split('/').filter(Boolean).pop() + RESET);

  // --- контекст: токены и процент ---
  const cw = d.context_window;
  if (cw) {
    const used = (cw.total_input_tokens || 0) + (cw.total_output_tokens || 0);
    const size = cw.context_window_size;
    const pct = cw.used_percentage;
    let s = 'ctx ' + tok(used);
    if (size) s += '/' + tok(size);
    if (pct !== null && pct !== undefined) {
      s = heat(pct) + s + ' ' + Math.round(pct) + '%' + RESET;
    }
    parts.push(s);
  }

  // --- лимиты подписки ---
  const resetIn = (epoch) => {
    if (!epoch) return '';
    const mins = Math.round((epoch * 1000 - Date.now()) / 60000);
    if (mins <= 0) return '';
    let s;
    if (mins < 60) s = mins + 'м';
    else if (mins < 1440) s = Math.floor(mins / 60) + 'ч' + (mins % 60 ? String(mins % 60) + 'м' : '');
    else s = Math.floor(mins / 1440) + 'д' + (Math.floor((mins % 1440) / 60) || '') + (Math.floor((mins % 1440) / 60) ? 'ч' : '');
    return DIM + '(' + s + ')' + RESET;
  };

  const rl = d.rate_limits;
  if (rl) {
    for (const [key, label] of [['five_hour', '5ч'], ['seven_day', '7д']]) {
      const w = rl[key];
      if (w && w.used_percentage !== null && w.used_percentage !== undefined) {
        const p = Math.round(w.used_percentage);
        parts.push(heat(p) + label + ' ' + p + '%' + RESET + resetIn(w.resets_at));
      }
    }
  }

  // --- цена сессии ---
  const cost = d.cost && d.cost.total_cost_usd;
  if (typeof cost === 'number' && cost > 0) {
    parts.push(DIM + '$' + cost.toFixed(2) + RESET);
  }

  process.stdout.write(parts.join('  ') + '\n');
});
