# Week 1 Docs

The lab brief and the diagrams for Week 1.

| File | What it is |
|------|------------|
| [lab-brief.md](lab-brief.md) | The lab brief: business scenario, client requirements, technical rules, deliverables and rubric |
| [discovery.md](discovery.md) | Discovery report in Markdown (completed after the Week 1 build) |
| [Discovery Report.docx](Discovery%20Report.docx) | Discovery report in the course Word template (completed after the Week 1 build) |
| [architecture.drawio](architecture.drawio) | Editable draw.io file with 4 pages (open in VS Code with the Draw.io Integration extension) |
| [images/01-architecture.png](images/01-architecture.png) | Page 1: solution architecture |
| [images/02-access-change-flow.png](images/02-access-change-flow.png) | Page 2: how an access change flows from branch to audit record |
| [images/03-oncall-permission-decision.png](images/03-oncall-permission-decision.png) | Page 3: why `ec2-user-2` can never create compute |
| [images/04-secure-first-sign-in.png](images/04-secure-first-sign-in.png) | Page 4: secure first sign-in |

Open the diagrams in the browser: [app.diagrams.net](https://app.diagrams.net/#Hjadofils%2Fonward-aws-lab-journal%2Fmain%2Fweek-1-secure-onboarding%2Fdocs%2Farchitecture.drawio)

## Updating the images

The PNGs are exports of the draw.io pages and do not update on their own. After editing `architecture.drawio`, export again with **File > Export as > PNG** for each page, or run the headless exporter from this folder:

```bash
docker run --rm -v "$(pwd):/data" rlespinasse/drawio-export:v4.38.0 \
  --format png --scale 2 --border 20 --output images architecture.drawio
```

Then rename the exported files to match the names above.
