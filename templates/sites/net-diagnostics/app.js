(function () {
  var SAMPLES = 20;
  var arc = document.querySelector("[data-arc]");
  var latencyNode = document.querySelector("[data-latency]");
  var button = document.querySelector("[data-start]");
  var status = document.querySelector("[data-status]");

  function set(selector, value) {
    var node = document.querySelector(selector);
    if (node) node.textContent = value;
  }

  function show(ms) {
    latencyNode.textContent = Math.round(ms);
    var ratio = Math.min(1, ms / 300);
    arc.style.strokeDashoffset = String(283 - 283 * ratio);
  }

  function probe() {
    var url = "/favicon.svg?t=" + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
    var start = performance.now();
    return fetch(url, { cache: "no-store" }).then(function (response) {
      return response.arrayBuffer().then(function () { return performance.now() - start; });
    });
  }

  function median(values) {
    var sorted = values.slice().sort(function (a, b) { return a - b; });
    var middle = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
  }

  function run() {
    var results = [];
    button.disabled = true;
    status.textContent = "Testing…";
    function next() {
      if (results.length >= SAMPLES) return finish(results);
      probe().then(function (ms) {
        results.push(ms);
        show(ms);
        set("[data-samples]", results.length + " / " + SAMPLES);
        setTimeout(next, 120);
      }).catch(function () {
        status.textContent = "The test server did not respond. Try again later.";
        button.disabled = false;
      });
    }
    next();
  }

  function finish(results) {
    var med = median(results);
    var jitter = 0;
    for (var i = 1; i < results.length; i++) jitter += Math.abs(results[i] - results[i - 1]);
    jitter /= Math.max(1, results.length - 1);
    show(med);
    set("[data-ping]", med.toFixed(1) + " ms");
    set("[data-jitter]", jitter.toFixed(1) + " ms");
    set("[data-range]", Math.min.apply(null, results).toFixed(0) + " / " + Math.max.apply(null, results).toFixed(0) + " ms");
    status.textContent = med < 60 ? "Excellent connection to this server." : med < 150 ? "Good connection for streaming and calls." : "High latency — try a closer location.";
    button.disabled = false;
    button.textContent = "Run again";
  }

  var nav = performance.getEntriesByType && performance.getEntriesByType("navigation")[0];
  set("[data-proto]", (nav && nav.nextHopProtocol) || location.protocol.replace(":", ""));
  var connection = navigator.connection || {};
  set("[data-net]", connection.effectiveType ? connection.effectiveType.toUpperCase() + (connection.downlink ? " · ~" + connection.downlink + " Mbps" : "") : "unknown");
  set("[data-tz]", Intl.DateTimeFormat().resolvedOptions().timeZone || "unknown");
  set("[data-screen]", screen.width + " × " + screen.height + " @" + (window.devicePixelRatio || 1) + "x");
  set("[data-lang]", navigator.language || "unknown");
  var ua = navigator.userAgent;
  set("[data-ua]", /Firefox\//.test(ua) ? "Gecko" : /Chrome\//.test(ua) ? "Blink" : /Safari\//.test(ua) ? "WebKit" : "Other");

  button.addEventListener("click", run);
  setTimeout(run, 600);
})();
