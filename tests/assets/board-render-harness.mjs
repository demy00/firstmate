// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html>
// Prints one JSON document:
//   { stats:[{n,label}], decisions:[{title,repo,repo_tooltip,link,link_tooltip}],
//     underway|landed|charted:[{title,title_tooltip,sub,sub_tooltip,badges,pickable}] }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");


class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    const has = (c) => this.className.split(/\s+/).includes(c);
    const add = (c) => { if (!has(c)) this.className = (this.className + " " + c).trim(); };
    const remove = (c) => {
      this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" ");
    };
    this.classList = {
      add,
      remove,
      contains: has,
      // Captain's Call deals its cards by toggling stack classes, so the shim
      // needs the real three-argument shape to render that section at all.
      toggle: (c, force) => {
        const on = force === undefined ? !has(c) : !!force;
        if (on) add(c); else remove(c);
        return on;
      },
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener() {}
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
globalThis.window = {};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

// Underway, Landed and Charted all render the same row shape, so one reader
// serves all three and each section can be asserted on in its own right.
const rowOf = (row) => {
  const main = row.children.find((c) => c.className.includes("bb-row__main"));
  const titleNode = main?.children.find((c) => c.className.includes("bb-row__title"));
  const subNode = main?.children.find((c) => c.className.includes("bb-row__sub"));
  return {
    title: titleNode?.textContent ?? "",
    // A title wraps to as many lines as it needs and the sub line clamps, and
    // the renderer decides on a tooltip by measuring the laid-out line box
    // rather than guessing. This shim has no layout engine, so
    // nothing here ever measures as clamped and the renderer must leave these
    // empty; surface them so a renderer that tooltips unconditionally is caught.
    title_tooltip: titleNode?.title ?? "",
    sub: subNode?.textContent ?? "",
    sub_tooltip: subNode?.title ?? "",
    badges: badgesOf(row),
    pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
  };
};
const rowsOf = (node) =>
  node.children.filter((r) => r.className.split(/\s+/).includes("bb-row")).map(rowOf);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
const underway = rowsOf(byId.get("bb-underway") || new Node("div"));
const landed = rowsOf(byId.get("bb-landed") || new Node("div"));
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
// Captain's Call cards carry the repo identifier the captain reads first; it is
// single-line and ellipsised, so surface it and its tooltip the same way rows do.
const findDeep = (node, cls) => {
  for (const c of node.children) {
    if (c.className.split(/\s+/).includes(cls)) return c;
    const hit = findDeep(c, cls);
    if (hit) return hit;
  }
  return null;
};
const decisions = (byId.get("bb-call") || new Node("div")).children
  .filter((c) => c.className.includes("bb-decision"))
  .map((card) => {
    const repo = findDeep(card, "bb-decision__repo");
    const link = findDeep(card, "bb-decision__link");
    return {
      title: findDeep(card, "bb-decision__title")?.textContent ?? "",
      repo: repo?.textContent ?? "",
      repo_tooltip: repo?.title ?? "",
      link: link?.textContent ?? "",
      link_tooltip: link?.title ?? "",
    };
  });

const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

// The dispatch bar and the stack nav are the two controls the board withdraws
// when there is nothing to act on, and it withdraws them by attribute. Surface
// those markers: a renderer that stops setting them leaves the captain a
// "nothing picked" bar with a Queue button that is neither disabled nor wired.
const stacknavOf = (countId) => byId.get(countId)?.parentNode;
const controls = {
  dispatch_hidden: !!byId.get("bb-dispatch")?.hidden,
  stacknav_hidden: !!stacknavOf("bb-stack-count")?.hidden,
};

process.stdout.write(
  JSON.stringify({ stats, decisions, underway, landed, charted, empty, more, controls, error: errorText }) + "\n",
);
