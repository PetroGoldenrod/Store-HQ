// Parse a Verifone Commander day transaction log (LOGD###.XML from VSPoll) into cashier sessions and voids.
// Pure string parsing (no DOM): runs the same in Node and in a Cloudflare Worker.
const LOT = { "27": "online", "34": "scratch", "82": "onlinePay", "88": "scratchPay" };
const num = s => { const v = parseFloat(String(s == null ? "" : s).replace(/,/g, "")); return isFinite(v) ? v : 0; };
const tag = (s, t) => { const m = s.match(new RegExp("<" + t + "(?:\\s[^>]*)?>([\\s\\S]*?)</" + t + ">")); return m ? m[1] : ""; };
const attr = (s, a) => { const m = s.match(new RegExp("\\s" + a + "=\"([^\"]*)\"")); return m ? m[1] : ""; };
const unesc = s => String(s).replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").trim();
const r2 = v => Math.round(v * 100) / 100;

export function parseLog(xml) {
  const head = xml.slice(0, 600);
  const date = attr(head.match(/<transSet[^>]*>/)?.[0] || "", "longId");
  const out = { date, opened: tag(head + xml.slice(600, 2000), "openedTime"), closed: "", trans: [] };
  const cm = xml.match(/<closedTime>([^<]*)<\/closedTime>/); out.closed = cm ? cm[1] : "";
  const re = /<trans type="([^"]*)"([^>]*)>([\s\S]*?)<\/trans>/g; let m;
  while ((m = re.exec(xml))) {
    const type = m[1], tattrs = m[2], body = m[3];
    if (type === "journal") continue;
    const hdr = tag(body, "trHeader");
    const cTag = (hdr.match(/<cashier[^>]*>[^<]*<\/cashier>/) || body.match(/<cashier[^>]*>[^<]*<\/cashier>/) || [""])[0];
    const t = { type, suspended: /suspended="true"/.test(tattrs), cashier: unesc((cTag.match(/>([^<]*)</) || [])[1] || ""),
      cPos: attr(cTag, "posNum"), cPer: attr(cTag, "period"), body, hdr,
      date: (tag(hdr, "date") || "").slice(0, 19), reg: tag(hdr, "physicalRegisterID") || tag(tag(hdr, "trTickNum"), "posNum") || tag(hdr, "posNum"),
      seq: tag(tag(hdr, "trTickNum"), "trSeq"), orig: (tag(hdr, "originalCashier") || tag(body, "originalCashier")).trim(),
      completion: /fuelPrepayCompletion="true"/.test(tattrs) };
    const oc = (body.match(/<originalCashier[^>]*>/) || [""])[0]; t.oPos = attr(oc, "posNum"); t.oPer = attr(oc, "period");
    const ot = tag(hdr, "trOriginalTickNum"); t.oSeq = tag(ot, "trSeq"); t.oReg = tag(ot, "posNum");
    out.trans.push(t);
  }
  return out;
}

function lines(body) {
  const L = []; const re = /<trLine type="([^"]*)"[^>]*>([\s\S]*?)<\/trLine>/g; let m;
  while ((m = re.exec(body))) {
    const b = m[2], d = b.match(/<trlDept number="([^"]*)"(?:\s+type="([^"]*)")?[^>]*>/);
    L.push({ type: m[1], dept: d ? d[1] : "", deptType: d ? d[2] || "" : "", desc: unesc(tag(b, "trlDesc")), qty: num(tag(b, "trlQty")),
      tot: num(tag(b, "trlLineTot")), sign: tag(b, "trlSign"), netVoid: /<trlNetVoid\s*\/?>/.test(b) });
  }
  return L;
}
function paylines(body) {
  const P = []; const re = /<trPayline type="([^"]*)"([^>]*)>([\s\S]*?)<\/trPayline>/g; let m;
  while ((m = re.exec(body))) P.push({ type: m[1], dup: /duplicate="true"/.test(m[2]), name: unesc(tag(m[3], "trpPaycode")).toUpperCase(), amt: num(tag(m[3], "trpAmt")) });
  return P;
}
const shiftOf = iso => { const h = +iso.slice(11, 13); return (h >= 22 || h < 6) ? 1 : (h < 14 ? 2 : 3); };

// Build sessions from one or more day logs (pass yesterday's and today's so sessions crossing the day close are whole).
export function buildSessions(logs) {
  const S = {}; const key = (pos, per) => pos + "|" + per;
  const get = (pos, per, name) => S[key(pos, per)] || (S[key(pos, per)] = { reg: pos, period: per, cashier: name, open: "", close: "",
    sales: 0, cash: 0, credit: 0, debit: 0, foodstamp: 0, other: 0, tax: 0, fuel: 0, merch: 0, drops: 0, dropCount: 0, payouts: 0,
    drawerExpected: null, drawerEntered: null, noSales: 0, voidAmt: 0, voidCount: 0,
    lotto: { online: 0, onlineQty: 0, scratch: 0, scratchQty: 0, onlinePay: 0, onlinePayQty: 0, scratchPay: 0, scratchPayQty: 0 }, firstTx: "", lastTx: "" });
  const seen = new Set(), lastSale = {};
  const cardComp = [];
  for (const log of logs) for (const t of log.trans) {
    if (t.completion && t.oPer && !paylines(t.body).some(p => p.dup)) { const u = tag(t.hdr, "uniqueID"); if (!u || !seen.has(u)) { if (u) seen.add(u); cardComp.push(t); } continue; }
    if (!t.cashier || !t.cPer || t.cPer === "0") continue;
    const s = get(t.cPos, t.cPer, t.cashier);
    if (t.type === "openCashier") { s.open = (tag(t.body, "cOpenTime") || "").slice(0, 19); continue; }
    if (t.type === "closeCashier") { s.open = s.open || (tag(t.body, "cOpenTime") || "").slice(0, 19); s.close = (tag(t.body, "cCloseTime") || "").slice(0, 19); continue; }
    if (t.type === "printCashier") {
      const da = t.body.match(/<drawerAmount>([\s\S]*?)<\/drawerAmount>/g) || [];
      for (const d of da) if (/>CASH</.test(d)) { s.drawerExpected = num(tag(d, "ECRAmount")); s.drawerEntered = num(tag(d, "actualAmount")); }
      s.close = s.close || (tag(t.body, "cCloseTime") || "").slice(0, 19); continue;
    }
    const uid = tag(t.hdr, "uniqueID"); if (uid) { if (seen.has(uid)) continue; seen.add(uid); }
    if (t.date) { if (!s.firstTx || t.date < s.firstTx) s.firstTx = t.date; if (!s.lastTx || t.date > s.lastTx) s.lastTx = t.date; }
    if (t.type === "safedrop") { s.drops += num(tag(tag(t.body, "trValue"), "trCurrTot")); s.dropCount++; continue; }
    if (t.type === "nosale") { s.noSales++; continue; }
    if (/payout/i.test(t.type)) { s.payouts += num(tag(tag(t.body, "trValue"), "trCurrTot")); continue; }
    if (t.type === "void") { s.voidCount++; s.voidAmt += Math.abs(num(tag(tag(t.body, "trValue"), "trTotWTax"))); continue; }
    if (!/sale|refund/.test(t.type) || t.suspended) continue;
    if (t.orig) {
      // Prepay completion: the customer pumped less than they prepaid. Only the change handed back counts (the prepay itself was already rung).
      for (const p of paylines(t.body)) { if (p.dup) continue; const k = p.name === "CHANGE" ? "cash" : (p.name === "FOODSTAMP" ? "foodstamp" : p.name.toLowerCase()); if (k in s && typeof s[k] === "number") s[k] += p.amt; else s.other += p.amt; s.fuel += p.amt; }
      continue;
    }
    if (String(t.reg).startsWith("9")) continue;
    lastSale[(t.reg || t.cPos) + "|" + (t.seq || uid)] = t;
  }
  for (const t of Object.values(lastSale)) {
    const s = S[key(t.cPos, t.cPer)];
    const refund = /refund/.test(t.type);
    for (const p of paylines(t.body)) {
      if (p.dup) continue;
      let a = p.type === "cancel" ? -p.amt : p.amt; if (refund && p.name !== "CHANGE") a = -Math.abs(a);
      if (p.name === "CHANGE") s.cash += a; else if (p.name === "CASH") s.cash += a; else if (p.name === "CREDIT") s.credit += a;
      else if (p.name === "DEBIT") s.debit += a; else if (p.name === "FOODSTAMP") s.foodstamp += a; else s.other += a;
    }
    s.tax += num(tag(tag(t.body, "trValue"), "trTotTax"));
    for (const l of lines(t.body)) {
      if (l.type.startsWith("void")) { s.voidCount++; s.voidAmt += Math.abs(l.tot); continue; }
      if (l.netVoid) continue;
      const sg = l.sign && l.sign.startsWith("-") ? -1 : 1;
      if (/fuel/i.test(l.type) || l.deptType === "fuel") s.fuel += sg * l.tot; else s.merch += sg * l.tot;
      const k = LOT[l.dept];
      if (k) { const a = (k === "onlinePay" || k === "scratchPay") ? -Math.abs(l.tot) : l.tot; s.lotto[k] += a; s.lotto[k + "Qty"] += l.qty || 1; }
    }
  }
  // Card prepay finished at the pump: the register ticket held the prepay amount; the cashier is credited what was actually pumped.
  const bySeq = {}; for (const t of Object.values(lastSale)) if (t.seq) bySeq[t.reg + "|" + t.seq] = t;
  for (const c of cardComp) {
    const p = bySeq[c.oReg + "|" + c.oSeq], s = S[key(c.oPos, c.oPer)]; if (!p || !s) continue;
    const pre = lines(p.body).filter(l => l.type === "preFuel").reduce((a, l) => a + l.tot, 0);
    const fin = lines(c.body).filter(l => l.type === "postFuel").reduce((a, l) => a + l.tot, 0);
    const d = fin - pre; if (!d) continue;
    const pay = paylines(c.body)[0], k = pay ? (pay.name === "FOODSTAMP" ? "foodstamp" : pay.name.toLowerCase()) : "credit";
    if (k in s && typeof s[k] === "number") s[k] += d; else s.other += d; s.fuel += d;
  }
  return Object.values(S).map(s => {
    s.sales = s.cash + s.credit + s.debit + s.foodstamp + s.other;
    s.overShort = s.drawerExpected === null ? null : r2(s.drawerEntered - s.drawerExpected);
    const a = s.open || s.firstTx, b = s.close || s.lastTx;
    s.shift = a && b ? shiftOf(new Date((new Date(a + "Z").getTime() + new Date(b + "Z").getTime()) / 2).toISOString()) : (a ? shiftOf(a) : 0);
    for (const k of ["sales", "cash", "credit", "debit", "foodstamp", "other", "tax", "fuel", "merch", "drops", "payouts", "voidAmt"]) s[k] = r2(s[k]);
    for (const k in s.lotto) s.lotto[k] = r2(s.lotto[k]);
    return s;
  });
}

// Voids, refunds and no-sales per shift (same rules as the old Report Navigator pull).
export function buildVoids(log) {
  const seen = {};
  for (const t of log.trans) {
    if (t.suspended) continue;
    if (!/^(void|nosale|sale|network sale|refund|refund sale)$/.test(t.type)) continue;
    if (String(t.reg).startsWith("9") && t.type !== "nosale" && t.orig) continue;
    seen[t.type + "|" + (t.reg || "") + "|" + (t.seq || tag(t.hdr, "uniqueID"))] = t;
  }
  const ev = [];
  const base = t => ({ ts: t.date.slice(0, 16), reg: t.reg, cashier: t.cashier ? t.cashier.replace(/\b\w/g, c => c.toUpperCase()).replace(/\B\w+/g, w => w.toLowerCase()) : "" });
  for (const t of Object.values(seen)) {
    if (t.type === "nosale") { ev.push({ ...base(t), kind: "No sale", amount: 0, what: "" }); continue; }
    if (t.type === "void") {
      const amt = num(tag(tag(t.body, "trValue"), "trTotWTax"));
      if (String(t.reg).startsWith("9") && !amt) continue;
      ev.push({ ...base(t), kind: "Voided ticket", amount: amt, what: lines(t.body).map(l => l.desc).filter(Boolean).join(", ") }); continue;
    }
    for (const l of lines(t.body)) {
      if (l.type.startsWith("void")) ev.push({ ...base(t), kind: "Voided item", amount: Math.abs(l.tot), what: l.desc });
      else if ((l.sign || "").startsWith("-") && !/PAYOUT/i.test(l.desc)) ev.push({ ...base(t), kind: "Refund", amount: Math.abs(l.tot), what: l.desc });
    }
  }
  ev.sort((a, b) => a.ts < b.ts ? -1 : 1);
  for (const e of ev) {
    e.flag = "";
    if (e.kind === "No sale") e.flag = "Drawer opened with no sale";
    else if (e.kind === "Refund") e.flag = "Refund";
    else if (e.kind === "Voided ticket" && e.amount >= 20 && /[A-Z]/.test(e.what.toUpperCase().replace(/PREPAY CA #\d+|,|\s/g, ""))) e.flag = "Whole ticket voided with merchandise";
  }
  for (const e of ev) {
    if (e.kind !== "Voided item" || e.flag) continue;
    const t0 = Date.parse(e.ts + ":00Z");
    const same = ev.filter(x => x !== e && x.kind === "Voided item" && x.what === e.what && Math.abs(Date.parse(x.ts + ":00Z") - t0) <= 600000);
    if (same.length) e.flag = "Same item voided " + (same.length + 1) + " times in 10 min";
  }
  return [1, 2, 3].map(sh => {
    const items = ev.filter(e => shiftOf(e.ts) === sh).map(e => ({ time: e.ts.slice(11, 16), reg: e.reg, cashier: e.cashier, kind: e.kind, amount: r2(e.amount), what: e.what.slice(0, 90), flag: e.flag }));
    return { shift: sh, cashiers: [...new Set(items.map(i => i.cashier).filter(Boolean))].sort(), items };
  });
}

// Business date of a session: the Verifone day closes ~10 PM, so a session belongs to the date two hours after its midpoint.
export function sessionDate(s) {
  const a = s.open || s.firstTx, b = s.close || s.lastTx; if (!a || !b) return "";
  const mid = (Date.parse(a + "Z") + Date.parse(b + "Z")) / 2 + 2 * 3600e3;
  return new Date(mid).toISOString().slice(0, 10);
}

// Everything for the nightly import: logs = the newest 2-3 day logs (any order).
export function processLogs(xmls) {
  const logs = xmls.map(parseLog).filter(l => l.date).sort((a, b) => a.date < b.date ? -1 : 1);
  const all = buildSessions(logs).filter(s => s.close && (s.sales || s.drops || s.drawerExpected !== null));
  const dates = logs.slice(-2).map(l => l.date);   // the oldest log is only there to complete sessions that started before its close
  const out = [];
  for (const d of dates) {
    let ss = all.filter(s => sessionDate(s) === d).sort((a, b) => a.open < b.open ? -1 : 1);
    const merged = [];
    for (const x of ss) {
      const prev = [...merged].reverse().find(p => p.reg === x.reg && p.cashier === x.cashier);
      if (!x.cash && !x.credit && !x.debit && prev) {
        prev.drops = r2(prev.drops + x.drops); prev.dropCount += x.dropCount; prev.overShort = r2((prev.overShort || 0) + (x.overShort || 0));
        prev.note = "Includes a " + (x.open || "").slice(11, 16) + " session with no sales: $" + x.drops.toFixed(2) + " drop, over/short " + ((x.overShort || 0) >= 0 ? "+" : "") + (x.overShort || 0).toFixed(2);
        continue;
      }
      merged.push(x);
    }
    const sessions = merged.map(s => ({ sid: s.reg + "-" + s.period + "-" + s.close, reg: s.reg, cashier: s.cashier.replace(/\b\w/g, c => c.toUpperCase()).replace(/\B\w+/g, w => w.toLowerCase()),
      open: s.open || s.firstTx, close: s.close, shift: s.shift, sales: s.sales, cash: s.cash, credit: s.credit, debit: s.debit, foodstamp: s.foodstamp, tax: s.tax,
      fuel: s.fuel, merch: r2(s.sales - s.fuel - s.tax), drops: s.drops, dropCount: s.dropCount, payouts: s.payouts,
      drawerExpected: s.drawerExpected, drawerEntered: s.drawerEntered, overShort: s.overShort, noSales: s.noSales, voidAmt: s.voidAmt, voidCount: s.voidCount,
      lotto: s.lotto, note: s.note || "" }));
    const log = logs.find(l => l.date === d);
    out.push({ date: d, sessions, voids: buildVoids(log) });
  }
  return out;
}
