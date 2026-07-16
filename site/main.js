// Loop Runner landing page — tiny, dependency-free interactions.
document.documentElement.classList.add("js");

const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/* ---------- copy buttons ---------- */
for (const btn of document.querySelectorAll("[data-copy]")) {
  btn.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(btn.dataset.copy);
      const label = btn.textContent;
      btn.textContent = "copied ✓";
      btn.disabled = true;
      setTimeout(() => {
        btn.textContent = label;
        btn.disabled = false;
      }, 1600);
    } catch {
      /* clipboard unavailable (e.g. non-secure context) — leave the text selectable */
    }
  });
}

/* ---------- mobile menu ---------- */
const menuBtn = document.getElementById("menu-btn");
const menu = document.getElementById("mobile-menu");
if (menuBtn && menu) {
  const setOpen = (open) => {
    menu.classList.toggle("hidden", !open);
    menuBtn.setAttribute("aria-expanded", String(open));
  };
  menuBtn.addEventListener("click", () => setOpen(menu.classList.contains("hidden")));
  menu.querySelectorAll("a").forEach((a) => a.addEventListener("click", () => setOpen(false)));
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") setOpen(false);
  });
  document.addEventListener("click", (e) => {
    if (!menu.classList.contains("hidden") && !menu.contains(e.target) && !menuBtn.contains(e.target)) setOpen(false);
  });
}

/* ---------- scroll reveals ---------- */
const revealables = document.querySelectorAll(".reveal");
if ("IntersectionObserver" in window && !reduced) {
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          e.target.classList.add("in");
          io.unobserve(e.target);
        }
      }
    },
    { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
  );
  revealables.forEach((el) => io.observe(el));
} else {
  revealables.forEach((el) => el.classList.add("in"));
}

/* ---------- terminal typewriter ---------- */
const term = document.getElementById("terminal");
if (term) {
  const CMD = "gcloud run jobs execute loop-hello-world --wait";
  const LINES = [
    { html: '<span class="text-cream/60">⠿ cloning SaschaHeyer/loop-runner</span> <span class="text-cream/35">(spec + prompt + verifier + skills)</span>', d: 750 },
    { html: '<span class="text-led">✓</span> proxy live, CA trusted', d: 700 },
    { html: '<span class="text-lav-soft">▸</span> agent up <span class="text-cream/35">· claude on vertex · max_turns=6 · budget $1</span>', d: 650 },
    { html: '<span class="text-cream/55">&nbsp;&nbsp;· reads loops/hello-world/state/greetings.md</span>', d: 750 },
    { html: '<span class="text-cream/55">&nbsp;&nbsp;· appends one timestamped greeting</span>', d: 650 },
    { html: '<span class="text-led">✓</span> verify.sh → exit 0 <span class="text-cream/35">(a real check, not a self-grade)</span>', d: 850 },
    { html: '<span class="text-led">✓</span> stop hook · commit + push <span class="text-cream/35">(the persistence guarantee)</span>', d: 700 },
    { html: '<span class="font-bold text-led">work_done=1 pushed=true</span>', d: 800 },
    { html: '<span class="text-led">✓</span> transcript + cost → gs://…/sessions/', d: 650 },
    { html: '<span class="italic text-cream/40">— run complete · the repo remembers ✦</span>', d: 950 },
  ];

  const promptHtml = '<span class="text-lav-soft">$</span> ';

  const renderStatic = () => {
    term.innerHTML =
      `<div>${promptHtml}${CMD}</div>` +
      LINES.map((l) => `<div>${l.html}</div>`).join("");
  };

  if (reduced) {
    renderStatic();
  } else {
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    let running = false;

    const play = async () => {
      if (running) return;
      running = true;
      for (;;) {
        term.innerHTML = "";
        const cmdLine = document.createElement("div");
        cmdLine.innerHTML = promptHtml + '<span class="terminal-caret"></span>';
        term.appendChild(cmdLine);
        const caret = cmdLine.querySelector(".terminal-caret");
        await sleep(500);
        for (let i = 0; i < CMD.length; i++) {
          caret.insertAdjacentText("beforebegin", CMD[i]);
          await sleep(24 + Math.random() * 26);
        }
        await sleep(450);
        caret.remove();
        for (const line of LINES) {
          await sleep(line.d);
          const el = document.createElement("div");
          el.innerHTML = line.html;
          term.appendChild(el);
        }
        await sleep(5200);
      }
    };

    // start when the terminal scrolls into view
    if ("IntersectionObserver" in window) {
      const tio = new IntersectionObserver((entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          play();
          tio.disconnect();
        }
      }, { threshold: 0.25 });
      tio.observe(term);
    } else {
      play();
    }
  }
}
