(function () {
  var authors = ["Maya Lindqvist", "Daniel Okafor", "Priya Raman", "Tomás Herrera", "Lena Vogel", "Kenji Sato"];
  var seed = __SEED__;
  var author = document.querySelector("[data-author]");
  if (author) author.textContent = authors[seed % authors.length];

  var dates = document.querySelectorAll("[data-date]");
  var day = 86400000;
  var offset = 2 + (seed % 5);
  Array.prototype.forEach.call(dates, function (node, index) {
    var date = new Date(Date.now() - (offset + index * (6 + (seed + index) % 9)) * day);
    node.textContent = date.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
  });
})();
