# Demo lecture for the README pictures

The pictures and the GIF in the [README](../../README.md) show this demo lecture, not real course material:

- `homographies.tex`: an 11-slide Beamer deck, *Homographies and RANSAC* (`pdflatex homographies.tex`). The compiled deck is `03 Homographies and RANSAC.pdf`.
- `03 Homographies walkthrough.html`: a study page for it. Each section names its slides (`data-pages="8-9"`), which is how the Walkthrough tab scrolls with the slides. Put a copy of `Sources/CoLearner/Web/vendor/katex` next to it as `katex/` so its math renders.

The demo library also had a few short decks for Robotics and Machine Learning, so the lecture page has more than one section.

## How the pictures were taken

A debug build (`swift build`) was run with a scratch support folder whose `library.json` lists the demo course folders and links the walkthrough page to the deck, and with `COLEARNER_SCRIPT` driving it. For example, the first picture:

```text
chrome on; size 1440 860; pdf <demo folder>/Computer Vision/slides/03 Homographies and RANSAC.pdf; wait 3;
slide 5; ask claude Why is h the last column of V? I don't see why the smallest singular value minimizes ‖Ah‖.;
idle 300; chatjs document.getElementById('log').scrollTop = 0, 1; shot hero-light.png; appearance dark; wait 2.5;
shot hero-dark.png; quit
```

The answers are real Claude (Opus 5.5, medium effort) answers, asked through the app. `shot` draws the window itself, so no screen recording is involved; the corners and shadow were added afterwards. All script steps are listed in [DEVELOPMENT.md](../DEVELOPMENT.md#building).
