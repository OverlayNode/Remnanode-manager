(function () {
  var P = "__P__";
  var units = {
    length: { m: ["Meter", 1], km: ["Kilometer", 1000], cm: ["Centimeter", 0.01], mm: ["Millimeter", 0.001], mi: ["Mile", 1609.344], yd: ["Yard", 0.9144], ft: ["Foot", 0.3048], in: ["Inch", 0.0254] },
    mass: { kg: ["Kilogram", 1], g: ["Gram", 0.001], t: ["Tonne", 1000], lb: ["Pound", 0.45359237], oz: ["Ounce", 0.028349523125] },
    temperature: { c: ["Celsius", 0, "°C"], f: ["Fahrenheit", 0, "°F"], k: ["Kelvin", 0, "K"] },
    data: { B: ["Byte", 1], KB: ["Kilobyte", 1e3], MB: ["Megabyte", 1e6], GB: ["Gigabyte", 1e9], TB: ["Terabyte", 1e12], KiB: ["Kibibyte", 1024], MiB: ["Mebibyte", 1048576], GiB: ["Gibibyte", 1073741824] },
    speed: { "m/s": ["Meter/second", 1], "km/h": ["Kilometer/hour", 1 / 3.6], mph: ["Mile/hour", 0.44704], kn: ["Knot", 0.514444] }
  };
  var defaults = { length: ["km", "mi"], mass: ["kg", "lb"], temperature: ["c", "f"], data: ["GB", "GiB"], speed: ["km/h", "mph"] };
  var kind = "length";

  var fromValue = document.querySelector("[data-from-value]");
  var toValue = document.querySelector("[data-to-value]");
  var fromUnit = document.querySelector("[data-from-unit]");
  var toUnit = document.querySelector("[data-to-unit]");
  var formula = document.querySelector("[data-formula]");
  var common = document.querySelector("[data-common]");

  function toKelvin(value, unit) {
    if (unit === "c") return value + 273.15;
    if (unit === "f") return (value - 32) * 5 / 9 + 273.15;
    return value;
  }
  function fromKelvin(value, unit) {
    if (unit === "c") return value - 273.15;
    if (unit === "f") return (value - 273.15) * 9 / 5 + 32;
    return value;
  }
  function convert(value, from, to) {
    if (kind === "temperature") return fromKelvin(toKelvin(value, from), to);
    return value * units[kind][from][1] / units[kind][to][1];
  }
  function symbol(unit) {
    return units[kind][unit][2] || unit;
  }
  function format(value) {
    if (!isFinite(value)) return "—";
    var abs = Math.abs(value);
    if (abs !== 0 && (abs < 1e-4 || abs >= 1e12)) return value.toExponential(6);
    return parseFloat(value.toPrecision(10)).toLocaleString("en-US", { maximumFractionDigits: 8 });
  }
  function fill(select, selected) {
    while (select.firstChild) select.removeChild(select.firstChild);
    Object.keys(units[kind]).forEach(function (key) {
      var option = document.createElement("option");
      option.value = key;
      option.textContent = units[kind][key][0] + " (" + symbol(key) + ")";
      option.selected = key === selected;
      select.appendChild(option);
    });
  }
  function update() {
    var value = parseFloat(fromValue.value);
    if (isNaN(value)) { toValue.value = ""; formula.textContent = ""; return; }
    var result = convert(value, fromUnit.value, toUnit.value);
    toValue.value = format(result);
    formula.textContent = format(value) + " " + symbol(fromUnit.value) + " = " + format(result) + " " + symbol(toUnit.value);
  }
  function renderCommon() {
    while (common.firstChild) common.removeChild(common.firstChild);
    var keys = Object.keys(units[kind]);
    keys.slice(0, 5).forEach(function (from, index) {
      var to = keys[(index + 1) % keys.length];
      var row = document.createElement("tr");
      var left = document.createElement("td");
      left.textContent = "1 " + units[kind][from][0];
      var right = document.createElement("td");
      right.textContent = format(convert(1, from, to)) + " " + symbol(to);
      row.appendChild(left);
      row.appendChild(right);
      common.appendChild(row);
    });
  }
  function selectKind(next) {
    kind = next;
    fill(fromUnit, defaults[kind][0]);
    fill(toUnit, defaults[kind][1]);
    Array.prototype.forEach.call(document.querySelectorAll("[data-kind]"), function (tab) {
      tab.classList.toggle(P + "active", tab.getAttribute("data-kind") === kind);
    });
    renderCommon();
    update();
  }

  Array.prototype.forEach.call(document.querySelectorAll("[data-kind]"), function (tab) {
    tab.addEventListener("click", function () { selectKind(tab.getAttribute("data-kind")); });
  });
  document.querySelector("[data-swap]").addEventListener("click", function () {
    var from = fromUnit.value;
    fromUnit.value = toUnit.value;
    toUnit.value = from;
    update();
  });
  [fromValue, fromUnit, toUnit].forEach(function (node) {
    node.addEventListener("input", update);
    node.addEventListener("change", update);
  });

  var kinds = Object.keys(units);
  selectKind(kinds[__SEED__ % kinds.length]);
})();
