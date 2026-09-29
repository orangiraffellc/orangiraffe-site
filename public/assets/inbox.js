// Inbox helpers: select all, local times, and a confirm before deleting.
// The page works without this script; it only adds conveniences.
document.addEventListener("DOMContentLoaded", function () {
  var form = document.getElementById("inbox-form");
  var all = document.getElementById("select-all");
  function boxes() { return Array.prototype.slice.call(document.querySelectorAll('input[name="id"]')); }

  if (all) {
    all.closest("label").hidden = false;
    all.addEventListener("change", function () {
      boxes().forEach(function (b) { b.checked = all.checked; });
    });
    boxes().forEach(function (b) {
      b.addEventListener("change", function () {
        var bs = boxes(), on = bs.filter(function (x) { return x.checked; }).length;
        all.checked = on === bs.length;
        all.indeterminate = on > 0 && on < bs.length;
      });
    });
  }

  document.querySelectorAll("time[datetime]").forEach(function (t) {
    var d = new Date(t.dateTime);
    if (!isNaN(d)) t.textContent = d.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  });

  if (form) {
    form.addEventListener("submit", function (e) {
      var btn = e.submitter;
      var n = btn && btn.value === "delete_all"
        ? Number(form.dataset.count)
        : boxes().filter(function (b) { return b.checked; }).length;
      if (n === 0) { e.preventDefault(); return; }
      var what = n === 1 ? "1 message" : n + " messages";
      if (!window.confirm("Delete " + what + "? This cannot be undone.")) e.preventDefault();
    });
  }
});
