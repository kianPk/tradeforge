(() => {
  const markets = {
    eth: { price: 2000, feeBps: 10, mmrBps: 500, maxLev: 20 },
    btc: { price: 60000, feeBps: 10, mmrBps: 500, maxLev: 10 },
  };
  let side = "long";

  const $ = (id) => document.getElementById(id);
  const fmt = (n, d = 2) =>
    n.toLocaleString(undefined, { maximumFractionDigits: d, minimumFractionDigits: d });

  document.querySelectorAll(".tab").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.querySelectorAll(".tab").forEach((b) => b.classList.remove("on"));
      btn.classList.add("on");
      side = btn.dataset.side;
      render();
    });
  });

  ["market", "size", "margin", "move"].forEach((id) => {
    $(id).addEventListener("input", render);
  });

  function render() {
    const m = markets[$("market").value];
    const size = Math.max(0.01, Number($("size").value) || 0);
    const margin = Math.max(1, Number($("margin").value) || 0);
    const move = Number($("move").value) || 0;
    $("moveVal").textContent = (move >= 0 ? "+" : "") + move + "%";

    const entry = m.price;
    const mark = entry * (1 + move / 100);
    const signed = side === "long" ? size : -size;
    const notional = size * mark;
    const fee = (size * entry * m.feeBps) / 10000;
    const marginNet = Math.max(0, margin - fee);
    const lev = marginNet > 0 ? (size * entry) / marginNet : Infinity;
    const pnl = signed * (mark - entry);
    const equity = marginNet + pnl;
    const maint = (notional * m.mmrBps) / 10000;

    $("oNotional").textContent = "$" + fmt(notional, 0);
    $("oLev").textContent = Number.isFinite(lev) ? fmt(lev, 2) + "x" : "∞";
    $("oFee").textContent = "$" + fmt(fee, 2);

    const pnlEl = $("oPnl");
    pnlEl.textContent = (pnl >= 0 ? "+" : "") + "$" + fmt(pnl, 2);
    pnlEl.className = pnl >= 0 ? "up" : "down";

    const eqEl = $("oEq");
    eqEl.textContent = "$" + fmt(equity, 2);
    eqEl.className = equity >= 0 ? "up" : "down";

    const st = $("oStatus");
    if (lev > m.maxLev) {
      st.textContent = "over leverage";
      st.className = "down";
    } else if (equity <= 0 || equity < maint) {
      st.textContent = "liquidatable";
      st.className = "warn";
    } else {
      st.textContent = "healthy";
      st.className = "up";
    }
  }

  render();
})();
