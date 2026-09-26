(function () {
  var regions = ["eu-central", "eu-west", "eu-north", "us-east", "ap-south"];
  var seed = __SEED__;
  var node = document.querySelector("[data-region]");
  if (node) {
    node.textContent = regions[seed % regions.length];
  }
})();
