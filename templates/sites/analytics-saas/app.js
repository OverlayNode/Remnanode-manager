(function () {
  var NS = "http://www.w3.org/2000/svg";
  var svg = document.querySelector("[data-chart]");
  if (!svg) return;

  var seed = __SEED__ | 0;
  function random() {
    seed = (seed + 0x6d2b79f5) | 0;
    var t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  var points = [];
  var value = 90;
  for (var i = 0; i < 30; i++) {
    value += (random() - 0.4) * 18;
    value = Math.max(40, Math.min(185, value));
    points.push([i * (600 / 29), 210 - value]);
  }

  function path(list) {
    return list.map(function (p, index) { return (index ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1); }).join(" ");
  }

  var hue = getComputedStyle(document.documentElement).getPropertyValue("--h").trim() || "220";
  var defs = document.createElementNS(NS, "defs");
  var gradient = document.createElementNS(NS, "linearGradient");
  gradient.setAttribute("id", "fill");
  gradient.setAttribute("x1", "0"); gradient.setAttribute("x2", "0");
  gradient.setAttribute("y1", "0"); gradient.setAttribute("y2", "1");
  [["0", ".35"], ["1", "0"]].forEach(function (stop) {
    var node = document.createElementNS(NS, "stop");
    node.setAttribute("offset", stop[0]);
    node.setAttribute("stop-color", "hsl(" + hue + ",80%,56%)");
    node.setAttribute("stop-opacity", stop[1]);
    gradient.appendChild(node);
  });
  defs.appendChild(gradient);
  svg.appendChild(defs);

  for (var line = 1; line < 5; line++) {
    var grid = document.createElementNS(NS, "line");
    grid.setAttribute("x1", "0"); grid.setAttribute("x2", "600");
    grid.setAttribute("y1", String(line * 44)); grid.setAttribute("y2", String(line * 44));
    grid.setAttribute("stroke", "#ebecf5");
    svg.appendChild(grid);
  }

  var area = document.createElementNS(NS, "path");
  area.setAttribute("d", path(points) + " L600 220 L0 220 Z");
  area.setAttribute("fill", "url(#fill)");
  svg.appendChild(area);

  var stroke = document.createElementNS(NS, "path");
  stroke.setAttribute("d", path(points));
  stroke.setAttribute("fill", "none");
  stroke.setAttribute("stroke", "hsl(" + hue + ",80%,56%)");
  stroke.setAttribute("stroke-width", "2.5");
  stroke.setAttribute("vector-effect", "non-scaling-stroke");
  svg.appendChild(stroke);

  var users = document.querySelector('[data-kpi="users"]');
  if (users) users.textContent = (30000 + Math.floor(random() * 40000)).toLocaleString("en-US");
  var sessions = document.querySelector('[data-kpi="sessions"]');
  if (sessions) sessions.textContent = (120000 + Math.floor(random() * 150000)).toLocaleString("en-US");
  var conv = document.querySelector('[data-kpi="conv"]');
  if (conv) conv.textContent = (2 + random() * 4).toFixed(2) + "%";
})();
