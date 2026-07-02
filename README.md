# Seasonal movement patterns of Alpine ibex (Capra ibex) in the canton of Valais: Data-driven segmentation using combined GPS and NSD trajectories with HDBSCAN clustering

This repository contains the reproducible computational processing framework developed for the spatial cleaning, enrichment, metric calculation, and machine-learning segmentation of Alpine Ibex (*Capra ibex*) GPS telemetry data in the Swiss Canton of Valais.

## Pipeline Architecture & Orchestration

The system operates as a decoupled, sequential 5-stage data processing pipeline combining R (v4.x) and Python (v3.x). Each script acts as a modular unit that can be executed independently or connected within a shell runner workflow.

```text
  [ Raw Coordinates (CSV) ] 
             │ 
             ▼ (01_preprocess_basic.R)
  [ Cleaned Trajectories (GPKG) ]
             │ 
             ▼ (02_assign_z_values.R using swissALTI3D)
  [ 3D Geospatial Points (GPKG) ]
             │ 
             ▼ (03_nsd_classification.R)
  [ Net Squared Displacement Matrix (CSV) ]
             │ 
             ▼ (04_clustering.py using HDBSCAN)
  [ Segmented Behavioral States (GPKG) ]
             │ 
             ▼ (05_environmental_context.R using AS17 & Terrain)
  [ Final Analysis-Ready Contextual Buffers (GPKG) ]

```

---

## Execution & Operational Steps

Ensure all required spatial resources are present in your local file path structure, then run the workflow files sequentially using your terminal prompt:

### Step 1: Spatiotemporal Standardization

Cleans coordinates, localizes system tracking time zones to Central European Time (`Europe/Zurich`), projects points into the official Swiss coordinates reference system **CH1903+ / LV95 (EPSG:2056)**, and enforces biological constraints ($\ge 30$ baseline tracking days per season).

```bash
Rscript scripts/01_preprocess_basic.R data/raw_data.csv data/preprocessed_points.gpkg

```

### Step 2: Topographic Metric Extraction

Enriches the 2D coordinate points layout with spatial terrain attributes extracted from the high-resolution swisstopo **swissALTI3D Digital Elevation Model**, utilizing automated tracking-collar barometric sensor measurements as alternative fallback records.

```bash
Rscript scripts/02_assign_z_values.R data/preprocessed_points.gpkg data/dem/swissALTI3D_mosaic.tif data/enriched_3d_points.gpkg

```

### Step 3: Trajectory Metric Calculation

Iterates through track segments to determine optimal baseline winter anchor location reference matrix configurations and maps matching individual time-series scale **Net Squared Displacement (NSD)** matrices.

```bash
Rscript scripts/03_nsd_classification.R data/enriched_3d_points.gpkg data/nsd_curves.csv

```

### Step 4: Machine Learning Behavioral Clustering

Standardizes trajectory profiles using min-max scaling alongside custom time-space feature coordinate stretching parameters. Executes unsupervised density-based spatial partitioning via **HDBSCAN**, combined with spatial core percentile filtering and local rolling lookahead constraints to isolate seasonal migration tracks (`state = -1`) from home-range patches (`state = 0`).

```bash
python scripts/04_clustering.py data/enriched_3d_points.gpkg data/nsd_curves.csv data/classified_trajectories.gpkg

```

### Step 5: Environmental Context Buffering & Annotation

Constructs localized trajectory vectors from classified migration tracks, creates an adjustable lateral search corridor zone (e.g., $200\text{m}$ buffer), aggregates zonal topographic profiles (Elevation, Slope, Aspect, Roughness, TRI), and overlays categorical land-cover classifications derived from the Swiss **Arealstatistik (AS17)** vectors.

```bash
Rscript scripts/05_environmental_context.R data/classified_trajectories.gpkg data/dem/dem25m.tif data/landuse/arealstatistik2056.gpkg 200 data/final_segments.gpkg

```

---

## Computational Requirements

The environment setup relies on standard geospatial processing engines:

* **R Package Requirements:** `sf`, `terra`, `dplyr`, `tidyr`, `readr`, `lubridate`, `data.table`
* **Python Environment Requirements:** `geopandas`, `pandas`, `numpy`, `hdbscan`, `scikit-learn`
