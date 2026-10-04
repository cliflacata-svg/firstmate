const { createJiti } = require("/home/clif/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/jiti");
const jiti = createJiti(__filename);
(async () => {
const root = "/home/clif/.no-mistakes/worktrees/be2e8740e3ea/01M441ZF9745RQW8VGE09E1Q5X/.claude/mods/firstmate-calm/lib/";
const notes = await jiti.import(root + "fm-branch-notes.ts");
const sp = await jiti.import(root + "fm-calm-working-ship-sprite.ts");
const row = (seq, verdict) => ({ seq, verdict, task: "t-" + seq, summary: "merged PR", silent: false });
for (const m of ["starfleet", "nautical"]) {
  console.log("motif", m);
  console.log("  routine:", notes.outcomeNoteLine(row(3, "routine"), m));
  console.log("  captain:", notes.outcomeNoteLine(row(4, "captain"), m));
  console.log("  health :", notes.hostHealthNote({ key: "k", cooling: false }, { key: "k", cooling: true }, m));
  console.log("  missed :", notes.newOutcomeNotes([row(9, "routine")], 5, m).lines[0]);
}
console.log("default (no motif arg):", notes.outcomeNoteLine(row(1, "routine")));
const cells = (r) => r.map((x) => x.text).join("");
for (const w of [2, 3, 4, 5, 6]) {
  const s = sp.createCalmWorkingShipSprite("starfleet");
  const seen = new Set();
  for (let i = 0; i < 120; i++) { const f = s.frame(w); seen.add(f.map(cells).join(" / ")); s.tick(); }
  console.log("starfleet width", w, [...seen].filter(x => x.includes("◆")).sort().join("  |  ") || [...seen][0]);
}
})();
