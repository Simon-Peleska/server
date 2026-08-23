/* Zerlegt die Überschriften in Wörter, damit jedes einzeln hochfahren kann.
   Mehrere Zeilen zählen gemeinsam weiter, sonst starten sie alle zugleich.
   Ohne JavaScript bleiben die Überschriften einfach sichtbar. */
(function () {
  var headings = document.querySelectorAll("[data-split]");
  if (!headings.length) return;

  var d = 0;

  Array.prototype.forEach.call(headings, function (heading, zeile) {
    if (zeile) d += 2; // eine kurze Pause zwischen zwei Zeilen

    var words = heading.textContent.trim().split(/\s+/);
    heading.textContent = "";

    words.forEach(function (word, i) {
      var mask = document.createElement("span");
      mask.className = "w";
      mask.style.setProperty("--d", d++);

      var inner = document.createElement("i");
      inner.textContent = word;

      mask.appendChild(inner);
      heading.appendChild(mask);
      if (i < words.length - 1) heading.appendChild(document.createTextNode(" "));
    });
  });
})();
