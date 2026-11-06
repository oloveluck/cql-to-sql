# Breast cancer screening, evaluated (slides)

The talk on evaluating NCQA's HEDIS Breast Cancer Screening measure (BCS-E, measurement year 2025):
the measure, the two methods (the CQL engine, and the CQL translated to one SQL query over
relational tables), the three test populations, the results, and the conclusions. 12 slides with
speaker notes.

| Slides | Part |
|---|---|
| 1–3 | The measure: the question it asks, and how NCQA publishes it as rules |
| 4–5 | The two methods: a rules engine (A) and a database query (B) |
| 6 | The datasets |
| 7–11 | The results: the summary table, then each dataset |
| 12 | Conclusions |

**The files** are the deck's source, in the Slides format of Claude artifacts:
- `deck.json`: the title, the slide order, the sections and the fonts;
- `slides/<id>.html`: one slide, on a 1920×1080 canvas, with its speaker notes in `<aside>`.

The presented copy, which exports to PowerPoint or PDF, is the artifact
https://claude.ai/artifact/Tjw3qK9A57pp1wx5dhaiUN (private until shared).

**Where the numbers come from:**

| Results | Command |
|---|---|
| The 19 hand-built members | `racket demo/bcse/run.rkt` |
| The 1,000 clinical-record-style members | `racket demo/bcse/population.rkt` |
| The what-if | `racket demo/bcse/population.rkt --supplemental` |
| The 1,000 insurance-claims-style members | `racket demo/bcse/hedis-population.rkt` |
| The two methods compared on the simplified measure | `raco test library.rkt` and `racket demo/run.rkt` |

`demo/bcse/README.md` says how to run them.
