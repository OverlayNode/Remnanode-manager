(function () {
  var windowMinutes = 90 + (__SEED__ % 150);
  var now = Date.now();
  // The window is anchored to the current half hour, so every visit shows a consistent ETA.
  var anchor = Math.floor(now / 1800000) * 1800000;
  var end = anchor + windowMinutes * 60000;
  if (end - now < 15 * 60000) end += 2 * 3600000;
  var total = end - anchor;

  function pad(value) { return (value < 10 ? "0" : "") + value; }
  function set(selector, value) {
    var node = document.querySelector(selector);
    if (node) node.textContent = value;
  }

  var eta = new Date(end);
  set("[data-eta]", eta.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) + " (" + Intl.DateTimeFormat().resolvedOptions().timeZone + ")");

  var bar = document.querySelector("[data-progress]");
  function tick() {
    var left = Math.max(0, end - Date.now());
    var seconds = Math.floor(left / 1000);
    set("[data-h]", pad(Math.floor(seconds / 3600)));
    set("[data-m]", pad(Math.floor((seconds % 3600) / 60)));
    set("[data-s]", pad(seconds % 60));
    if (bar) bar.style.width = Math.min(98, Math.max(8, (1 - left / total) * 100)).toFixed(1) + "%";
  }
  tick();
  setInterval(tick, 1000);
})();
