(function () {
  var seed = __SEED__ | 0;
  function random() {
    seed = (seed + 0x6d2b79f5) | 0;
    var t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  var P = "__P__";
  var components = ["API", "Dashboard", "Edge network", "Object storage", "Authentication", "Webhooks"];
  var container = document.querySelector("[data-components]");

  components.forEach(function (name) {
    var item = document.createElement("div");
    item.className = P + "component";

    var row = document.createElement("div");
    row.className = P + "component-row";
    var title = document.createElement("strong");
    title.textContent = name;
    var state = document.createElement("span");
    state.className = P + "state";
    state.textContent = "Operational";
    row.appendChild(title);
    row.appendChild(state);

    var bars = document.createElement("div");
    bars.className = P + "bars";
    var incidents = 0;
    for (var day = 0; day < 90; day++) {
      var bar = document.createElement("span");
      var roll = random();
      bar.className = P + "bar";
      if (roll > 0.985) { bar.className += " " + P + "bad"; incidents++; }
      else if (roll > 0.955) { bar.className += " " + P + "warn"; incidents++; }
      bar.title = (90 - day) + " days ago";
      bars.appendChild(bar);
    }

    var foot = document.createElement("div");
    foot.className = P + "bar-foot";
    var left = document.createElement("span");
    left.textContent = "90 days ago";
    var mid = document.createElement("span");
    mid.textContent = (100 - incidents * 0.07).toFixed(2) + "% uptime";
    var right = document.createElement("span");
    right.textContent = "Today";
    foot.appendChild(left);
    foot.appendChild(mid);
    foot.appendChild(right);

    item.appendChild(row);
    item.appendChild(bars);
    item.appendChild(foot);
    container.appendChild(item);
  });

  var titles = [
    ["Elevated API error rates", "A configuration change caused elevated 5xx responses for a subset of requests. The change was rolled back."],
    ["Delayed webhook delivery", "Webhook queues were processed with a delay of up to 12 minutes due to a stuck worker."],
    ["Scheduled database maintenance", "Planned maintenance of the primary database cluster completed without customer impact."],
    ["Increased latency in one region", "Traffic was shifted to neighbouring regions while an upstream network provider resolved packet loss."]
  ];
  var list = document.querySelector("[data-incidents]");
  var now = Date.now();
  titles.forEach(function (entry, index) {
    var node = document.createElement("div");
    node.className = P + "incident";
    var date = new Date(now - (index * 11 + 3 + Math.floor(random() * 6)) * 86400000);
    var time = document.createElement("time");
    time.textContent = date.toDateString();
    var head = document.createElement("h3");
    head.textContent = entry[0];
    var badge = document.createElement("span");
    badge.className = P + "resolved";
    badge.textContent = "Resolved";
    head.appendChild(badge);
    var text = document.createElement("p");
    text.textContent = entry[1];
    node.appendChild(time);
    node.appendChild(head);
    node.appendChild(text);
    list.appendChild(node);
  });

  var latency = document.querySelector("[data-latency]");
  if (latency) latency.textContent = (60 + Math.floor(random() * 50)) + " ms";
  var requests = document.querySelector("[data-requests]");
  if (requests) requests.textContent = (8 + random() * 30).toFixed(1) + "M";
})();
