(function () {
  var P = "__P__";
  var input = document.querySelector("[data-search]");
  var links = Array.prototype.slice.call(document.querySelectorAll("[data-nav] a"));

  if (input) {
    input.addEventListener("input", function () {
      var query = input.value.trim().toLowerCase();
      links.forEach(function (link) {
        var match = !query || link.textContent.toLowerCase().indexOf(query) !== -1;
        link.classList.toggle(P + "hidden", !match);
      });
    });
    document.addEventListener("keydown", function (event) {
      if (event.key === "/" && document.activeElement !== input) {
        event.preventDefault();
        input.focus();
      }
    });
  }

  links.forEach(function (link) {
    link.addEventListener("click", function () {
      links.forEach(function (other) { other.classList.remove(P + "active"); });
      link.classList.add(P + "active");
    });
  });
})();
