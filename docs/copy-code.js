// Copy-to-clipboard buttons for <pre> code blocks.
(function () {
  var COPY = '<svg viewBox="0 0 16 16" aria-hidden="true"><rect x="5" y="5" width="9" height="9" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M11 5V3.5A1.5 1.5 0 0 0 9.5 2h-6A1.5 1.5 0 0 0 2 3.5v6A1.5 1.5 0 0 0 3.5 11H5" fill="none" stroke="currentColor" stroke-width="1.4"/></svg>';
  var CHECK = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5 6.5 11.5 12.5 4.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  document.querySelectorAll("pre").forEach(function (pre) {
    var btn = document.createElement("button");
    btn.className = "copy-btn";
    btn.setAttribute("aria-label", "Copy to clipboard");
    btn.innerHTML = COPY;
    btn.addEventListener("click", function () {
      var code = pre.querySelector("code");
      var text = (code || pre).textContent;
      navigator.clipboard.writeText(text).then(function () {
        btn.innerHTML = CHECK;
        btn.classList.add("copied");
        setTimeout(function () {
          btn.innerHTML = COPY;
          btn.classList.remove("copied");
        }, 1500);
      });
    });
    pre.style.position = "relative";
    pre.appendChild(btn);
  });
})();
