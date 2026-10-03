// Phone menu: on narrow screens the nav collapses behind a button at the top
// right. Without JavaScript the button stays hidden and the links show as a
// normal row, so the site still works.
(function () {
  "use strict";
  var header = document.querySelector(".site-header");
  var button = header && header.querySelector(".nav-toggle");
  var nav = header && header.querySelector(".site-nav");
  if (!button || !nav) return;
  document.documentElement.classList.add("has-nav-toggle");
  button.hidden = false;

  function set(open) {
    header.classList.toggle("nav-open", open);
    button.setAttribute("aria-expanded", open ? "true" : "false");
    button.setAttribute("aria-label", open ? "Close menu" : "Open menu");
  }

  button.addEventListener("click", function () {
    set(button.getAttribute("aria-expanded") !== "true");
  });
  // Links like /#contact stay on the page, so close the menu after a tap.
  nav.addEventListener("click", function (event) {
    if (event.target.closest("a")) set(false);
  });
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape" && header.classList.contains("nav-open")) {
      set(false);
      button.focus();
    }
  });
})();
