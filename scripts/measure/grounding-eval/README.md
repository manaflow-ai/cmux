# Grounding eval (HQ#7146 G3c)

Picks the model behind Computer Use's grounding fallback: when an app's accessibility tree comes back thin
(canvas apps, games, Electron and Figma-type apps), the helper asks a vision model where an element is.
This eval measures the candidates offline, image only: one screenshot plus one element description in,
one point out. A point inside the target box counts as right.

| Benchmark | Samples | What it covers |
|---|---|---|
| [ScreenSpot-Pro](https://huggingface.co/datasets/likaixin/ScreenSpot-Pro) (MIT) | 1,581 | professional apps at up to 5K: dev tools, Creative (Blender, Photoshop, Premiere...), CAD, scientific, office, OS |
| [OSWorld-G](https://huggingface.co/datasets/MMInstruction/OSWorld-G) | 510 | desktop Linux apps, element types (icon, slider, dropdown...) |

`canvas` in each result is the subset where AX is thinnest: ScreenSpot-Pro's Creative and CAD groups,
and OSWorld-G's icons without a text label, images, sliders, colour pickers and grids.

## Candidates

`models.json` lists every candidate whose weights may ship (licences read from each card on 2026-11-05)
and the ones left out and why. Holo2-30B-A3B is CC-BY-NC-4.0 on its card, not Apache-2.0, so it is out.

## Run it

On a fleet GPU host (vLLM >= 0.13):

```
scripts/measure/grounding-eval/run.sh server=vllm [models=holo4-35b-a3b,opencua-32b] [limit=N]
```

On Apple silicon (mlx-vlm >= 0.7.12; `quant=8` or `quant=4` for the quantized weights):

```
scripts/measure/grounding-eval/run.sh server=mlx [models=holo-3.1-4b] [quant=bf16] [limit=N]
```

The first run downloads both datasets (about 9.5 GB) into `.build/grounding-eval/data`, or into
`$GROUNDING_EVAL_DATA`. Each model writes `.build/grounding-eval/<model>.json` (schema
`cmux.grounding-eval/1`, described at the top of `grounding_eval.py`), every answer to
`<model>.samples.jsonl`, and the run writes `summary.md`. `limit=N` takes N samples per benchmark,
spread over every app. A run that stops resumes where it left off.

Serving on its own, for the helper or by hand:

```
scripts/measure/grounding-eval/serve-mlx.sh holo-3.1-4b 8080       # prints the pid; kill it to stop
scripts/measure/grounding-eval/serve-vllm.sh holo4-35b-a3b 8000
```

Both listen on 127.0.0.1 and speak OpenAI's chat completions.

## What is held fixed

Batch 1, temperature 0, thinking off, no history. Each image is resized client-side the way the model's
own processor would (`smart_resize` with the card's pixel bounds), so the coordinates a model returns
map back exactly. Prompts are the ones on each model card. Samples run in a fixed shuffled order, and
the servers run without prefix or image caches, so a screenshot asked about twice is not answered from
cache. Latency is the client's wall time from sending a request to reading its answer (upload, prefill,
decode; the PNG encode is excluded), after one discarded warm-up request on a blank image. Memory is mlx-vlm's reported
peak, or the GPU memory `serve-vllm.sh` samples with nvidia-smi, marked "reserved" in the summary:
vLLM reserves 90% of the GPU up front, so that number is the reservation, not the need (the weights'
size is the floor). Holo on vLLM runs with structured outputs (its card's recommendation) and is marked
"(structured)"; on mlx it runs without. Errors are retried on `--resume`, and a run stops after 10 in a row.

Tests: `python3 tests/test_grounding_eval.py` (needs Pillow; no GPU, no network).
