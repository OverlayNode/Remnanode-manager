(function () {
  var P = "__P__";
  var figures = document.querySelectorAll("[data-gallery] figure");
  Array.prototype.forEach.call(figures, function (figure, index) {
    setTimeout(function () { figure.classList.add(P + "shown"); }, 120 * index);
  });

  var seasons = ["winter", "spring", "summer", "autumn"];
  var current = Math.floor(((new Date().getMonth() + 1) % 12) / 3);
  var node = document.querySelector("[data-season]");
  if (node) node.textContent = seasons[(current + 1) % 4];
})();
