// Contact form spam check. While the visitor fills in the form, the browser
// solves a small proof of work (SHA-256 of prefix + salt + ":" + nonce must
// start with data-pow-bits zero bits). form/contact.py verifies it, so scripts
// that post the form directly are dropped. Nothing is sent anywhere until the
// visitor presses Send. Links are refused here with a message, and again on
// the server (same rule as LINK_RE in form/contact.py).
(function () {
  "use strict";
  var form = document.querySelector("form.contact-form");
  if (!form) return;
  var button = form.querySelector('button[type="submit"]');
  var label = button.textContent;
  var note = form.querySelector(".form-error");
  var LINK_RE = /https?:\/\/|www\.|\[url|<a\s|href\s*=|\b[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}\/\S/i;
  var PREFIX = "orangiraffe-contact:";

  function say(text) {
    note.textContent = text;
    note.hidden = !text;
  }

  if (!(window.crypto && crypto.subtle && crypto.getRandomValues && window.TextEncoder)) {
    say("This browser cannot send the form. Please try a current version of Chrome, Safari, Firefox or Edge.");
    button.disabled = true;
    return;
  }

  var bits = parseInt(form.getAttribute("data-pow-bits"), 10) || 16;
  var opened = Date.now();
  var enc = new TextEncoder();
  var salt = newSalt();
  var solving = null;

  function newSalt() {
    var bytes = crypto.getRandomValues(new Uint8Array(16));
    return Array.prototype.map.call(bytes, function (b) { return (b < 16 ? "0" : "") + b.toString(16); }).join("");
  }

  function leadingZeros(d) {
    var full = bits >> 3, rest = bits & 7, i;
    for (i = 0; i < full; i++) if (d[i] !== 0) return false;
    return rest === 0 || (d[full] >> (8 - rest)) === 0;
  }

  async function solve() {
    var batch = 256, mine = salt;
    for (var start = 0; ; start += batch) {
      var tries = [];
      for (var n = start; n < start + batch; n++) {
        tries.push(crypto.subtle.digest("SHA-256", enc.encode(PREFIX + mine + ":" + n)));
      }
      var results = await Promise.all(tries);
      for (var k = 0; k < results.length; k++) {
        if (leadingZeros(new Uint8Array(results[k]))) return { salt: mine, nonce: start + k };
      }
    }
  }

  function begin() {
    if (!solving) solving = solve();
    return solving;
  }

  // Start once the visitor shows interest, so idle page views cost nothing.
  form.addEventListener("focusin", begin);
  form.addEventListener("input", begin);

  // Back from /thanks: the browser may restore this page as it was. Each
  // message needs a new puzzle (the server refuses a reused one), so reset.
  window.addEventListener("pageshow", function (event) {
    if (!event.persisted) return;
    salt = newSalt();
    solving = null;
    opened = Date.now();
    button.disabled = false;
    button.textContent = label;
  });

  form.addEventListener("submit", async function (event) {
    event.preventDefault();
    var name = form.elements.name.value, message = form.elements.message.value;
    if (LINK_RE.test(name) || LINK_RE.test(message)) {
      say("Please remove links from your message. To block spam, messages with links are not accepted.");
      form.elements.message.focus();
      return;
    }
    say("");
    button.disabled = true;
    button.textContent = "Sending...";
    try {
      var found = await begin();
      var wait = 3500 - (Date.now() - opened);
      if (wait > 0) await new Promise(function (r) { setTimeout(r, wait); });
      form.elements.pow_salt.value = found.salt;
      form.elements.pow_nonce.value = String(found.nonce);
      form.elements.elapsed.value = String(Date.now() - opened);
      form.submit();
    } catch (e) {
      solving = null;
      button.disabled = false;
      button.textContent = label;
      say("Something went wrong preparing your message. Please try again.");
    }
  });
})();
