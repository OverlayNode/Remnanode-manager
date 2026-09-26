(function () {
  var seasons = ["this winter", "this spring", "this summer", "this autumn"];
  var current = Math.floor(((new Date().getMonth() + 1) % 12) / 3);
  var node = document.querySelector("[data-release]");
  if (node) node.textContent = seasons[(current + 1 + (__SEED__ % 2)) % 4];
})();
