(function () {
  var P = "__P__";
  var pops = ["AMS", "FRA", "LHR", "CDG", "WAW", "HEL", "IAD", "ORD", "SJC", "GRU", "NRT", "SIN", "SYD", "BOM", "DXB", "JNB", "MAD", "MIL"];
  var grid = document.querySelector("[data-pops]");
  var seed = __SEED__;

  pops.forEach(function (code, index) {
    var item = document.createElement("div");
    item.className = P + "pop";
    var name = document.createElement("span");
    name.textContent = code;
    var state = document.createElement("i");
    state.textContent = (8 + ((seed + index * 7) % 30)) + " ms";
    item.appendChild(name);
    item.appendChild(state);
    grid.appendChild(item);
  });

  var current = document.querySelector("[data-pop]");
  if (current) current.textContent = pops[seed % pops.length];

  Array.prototype.forEach.call(document.querySelectorAll("[data-count]"), function (node) {
    var target = parseInt(node.getAttribute("data-count"), 10);
    var start = null;
    function step(time) {
      if (!start) start = time;
      var progress = Math.min(1, (time - start) / 1400);
      node.textContent = Math.round(target * (1 - Math.pow(1 - progress, 3)));
      if (progress < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  });
})();
