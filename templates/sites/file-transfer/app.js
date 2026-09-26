(function () {
  var bar = document.querySelector("[data-bar]");
  var label = document.querySelector("[data-progress]");
  if (!bar || !label) return;
  var value = 40 + (__SEED__ % 35);
  function tick() {
    value += Math.random() * 3;
    if (value >= 99) value = 38 + Math.random() * 10;
    bar.style.width = value.toFixed(1) + "%";
    label.textContent = Math.floor(value) + "%";
  }
  tick();
  setInterval(tick, 1400);
})();
