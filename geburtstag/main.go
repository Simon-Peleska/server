// Sechs Geschenke — ein kleiner Server, der die Geschenke einzeln freischaltet.
//
// Ein Geschenk taucht erst dann in der Übersicht und in der Blätter-Navigation
// auf, wenn seine Adresse einmal direkt aufgerufen wurde. Was schon
// freigeschaltet ist, merkt sich ein Cookie im Browser der Besucherin.
package main

import (
	"embed"
	"html/template"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
)

//go:embed templates/*.html assets/* img/*.jpg
var files embed.FS

// Geschenk ist eine der sechs Seiten.
type Geschenk struct {
	Nr    int
	Slug  string
	Titel string
	Bild  string
	Alt   string
	Focus template.CSS // Bildausschnitt, landet direkt im style-Attribut
	// Auf schmalen Schirmen wird seitlich viel weggeschnitten. Wo das den
	// Bildinhalt zerstört, steht hier ein eigener Ausschnitt; sonst leer.
	FocusMobil template.CSS
}

var geschenke = []Geschenk{
	{1, "staffelmarathon", "Ein Staffelmarathon in neuen Laufschuhen", "marathon.jpg", "Zieleinlauf bei einem Laufbewerb", "50% 42%", ""},
	{2, "therme", "Einen Tag in der Therme", "therme.jpg", "Schwimmen im Becken", "50% 50%", ""},
	{3, "wandern", "Ein Wochenende wandern", "wandern.jpg", "Sonniges Bergtal mit Wanderweg", "50% 45%", ""},
	// Sie sitzt rechts im Bild, darum schwenkt der Ausschnitt schmal ganz nach rechts.
	{4, "sonnensegel", "Ein Sonnensegel am Balkon", "balkon.jpg", "Zwei Menschen am Tisch auf dem Balkon", "50% 42%", "96% 40%"},
	{5, "klettern", "Einmal gemeinsam Klettern gehen", "klettern.jpg", "Klettergerüst mit Seilen vor blauem Himmel", "50% 48%", ""},
	{6, "kabarett", "Ein Besuch im Kabarett", "kabarett.jpg", "Kabarettist auf der Bühne", "50% 38%", ""},
}

const cookieName = "geschenke"

// freigeschaltet liest die bereits entdeckten Nummern aus dem Cookie.
func freigeschaltet(r *http.Request) map[int]bool {
	offen := map[int]bool{}
	c, err := r.Cookie(cookieName)
	if err != nil {
		return offen
	}
	for _, teil := range strings.Split(c.Value, "-") {
		if nr, err := strconv.Atoi(teil); err == nil && nr >= 1 && nr <= len(geschenke) {
			offen[nr] = true
		}
	}
	return offen
}

func merken(w http.ResponseWriter, offen map[int]bool) {
	var nummern []string
	for _, g := range geschenke {
		if offen[g.Nr] {
			nummern = append(nummern, strconv.Itoa(g.Nr))
		}
	}
	http.SetCookie(w, &http.Cookie{
		Name:     cookieName,
		Value:    strings.Join(nummern, "-"),
		Path:     "/",
		MaxAge:   60 * 60 * 24 * 365,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
}

type server struct{ tpl *template.Template }

func (s *server) uebersicht(w http.ResponseWriter, r *http.Request) {
	offen := freigeschaltet(r)
	var sichtbar []Geschenk
	for _, g := range geschenke {
		if offen[g.Nr] {
			sichtbar = append(sichtbar, g)
		}
	}
	s.render(w, "index.html", map[string]any{"Geschenke": sichtbar})
}

func (s *server) seite(w http.ResponseWriter, r *http.Request, g Geschenk) {
	// Der direkte Aufruf ist die Enthüllung: ab jetzt gehört das Geschenk dazu.
	offen := freigeschaltet(r)
	offen[g.Nr] = true
	merken(w, offen)

	// Vor und Zurück führen nur zu dem, was schon entdeckt ist.
	var vor, zurueck *Geschenk
	for i := range geschenke {
		nachbar := geschenke[i]
		if !offen[nachbar.Nr] || nachbar.Nr == g.Nr {
			continue
		}
		if nachbar.Nr < g.Nr {
			zurueck = &geschenke[i]
		}
		if nachbar.Nr > g.Nr && vor == nil {
			vor = &geschenke[i]
		}
	}

	s.render(w, "page.html", map[string]any{
		"Geschenk": g,
		"Zurueck":  zurueck,
		"Vor":      vor,
		"Gesamt":   len(geschenke),
	})
}

func (s *server) render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// Sonst zeigt der Zurück-Knopf eine Seite ohne die neu entdeckten Geschenke.
	w.Header().Set("Cache-Control", "no-store")
	if err := s.tpl.ExecuteTemplate(w, name, data); err != nil {
		log.Printf("Vorlage %s: %v", name, err)
	}
}

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	pfad := strings.Trim(r.URL.Path, "/")
	switch pfad {
	case "":
		s.uebersicht(w, r)
	case "reset": // zum Ausprobieren: alles wieder verstecken
		merken(w, nil)
		http.Redirect(w, r, "/", http.StatusSeeOther)
	default:
		for _, g := range geschenke {
			if g.Slug == pfad {
				s.seite(w, r, g)
				return
			}
		}
		http.NotFound(w, r)
	}
}

func main() {
	adresse := os.Getenv("ADDR")
	if adresse == "" {
		adresse = ":8080"
	}

	s := &server{tpl: template.Must(template.ParseFS(files, "templates/*.html"))}

	mux := http.NewServeMux()
	dateien := http.FileServer(http.FS(files))
	mux.Handle("/assets/", dateien)
	mux.Handle("/img/", dateien)
	mux.Handle("/", s)

	log.Printf("Sechs Geschenke laufen auf http://localhost%s", adresse)
	log.Fatal(http.ListenAndServe(adresse, mux))
}
