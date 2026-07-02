#!/usr/bin/env python3
import sys
import os
import pandas as pd
import numpy as np
import geopandas as gpd
import hdbscan
from sklearn.preprocessing import MinMaxScaler


# Argument validation
if len(sys.argv) < 3:
    print("Usage: python 04_clustering.py <input_gpkg> <input_nsd_csv> <output_gpkg>")
    sys.exit(1)

# ==========================================================
# Load preprocessed trajectory data and NSD curves
# ==========================================================

input_gpkg = sys.argv[1]
input_nsd_csv = sys.argv[2]
output_gpkg = sys.argv[3]

print("Loading preprocessed data and NSD curves...")
proc = gpd.read_file(input_gpkg)
nsd_raw = pd.read_csv(input_nsd_csv)


nsd_raw[["timestamp", "x", "y", "z", "daytime"]] = proc[
    ["timestamp", "x", "y", "z", "daytime"]
]

complete = []

# ==========================================================
# Process each individual trajectory independently
# ==========================================================

for ind in nsd_raw["id"].unique():

    individual = nsd_raw[nsd_raw["id"] == ind]

    # smooth NSD and derive first-order trend
    individual["nsd_smooth"] = (
        individual["nsd"]
        .rolling(window=32, center=True, min_periods=1)
        .mean()
    )
    individual["slope"] = individual["nsd_smooth"].diff().fillna(0)

    # ------------------------------------------------------
    # Temporal stretching:
    # preserves local temporal coherence in feature space
    # ------------------------------------------------------

    t_elapsed = (
        individual["timestamp"] - individual["timestamp"].min()
    ).dt.total_seconds()

    scale_factor = 2

    individual["x_stretched"] = individual["x"] + t_elapsed * scale_factor
    individual["y_stretched"] = individual["y"]
    individual["z_stretched"] = individual["z"]

    # clustering feature space
    features = individual[
        [
            "x_stretched",
            "y_stretched",
            "z_stretched",
            "nsd",
            "slope",
            "nsd_smooth"
        ]
    ]

    features_scaled = MinMaxScaler().fit_transform(features)

    # ======================================================
    # Initial HDBSCAN clustering
    # ======================================================

    clusterer = hdbscan.HDBSCAN(
        min_cluster_size=int(len(individual) / 55) + 5,
        min_samples=int(len(individual) / 55) + 5,
        cluster_selection_epsilon=0.09,
        metric="euclidean"
    )

    individual["cluster"] = clusterer.fit_predict(features_scaled)

    # ======================================================
    # Post-processing parameters
    # ======================================================

    MIN_SEGMENT_DAYS = 30
    MAX_OUTLIER_RUN = 32
    LOOKAHEAD = 3
    OUTLIER_RUN_MAX_DELTA = 0.2
    CORE = 90

    df = individual.copy()
    df["nsd_scaled"] = MinMaxScaler().fit_transform(df[["nsd"]])

    # ======================================================
    # Step 1: spatial core filtering
    # remove peripheral points within each cluster
    # ======================================================

    cluster_clean = df["cluster"].copy()

    for cl in df["cluster"].unique():

        if cl == -1:
            continue

        mask = df["cluster"] == cl
        coords = df.loc[mask, ["x", "y"]].values

        if len(coords) < 5:
            continue

        centroid = coords.mean(axis=0)
        dist = np.linalg.norm(coords - centroid, axis=1)

        threshold = np.percentile(dist, CORE)

        full_outlier_mask = np.zeros(len(df), dtype=bool)
        full_outlier_mask[mask.values] = dist > threshold

        cluster_clean.loc[full_outlier_mask] = -1

    df["cluster"] = cluster_clean

    # ======================================================
    # Step 2: temporal consistency filter
    # removes isolated edge artefacts
    # ======================================================

    cluster = df["cluster"].values.copy()
    n = len(cluster)

    for i in range(n):

        cl = cluster[i]

        if cl == -1:
            continue

        end = min(i + LOOKAHEAD + 1, n)
        future = cluster[i:end]

        if np.sum(future == cl) < LOOKAHEAD:
            cluster[i] = -1

    df["cluster"] = cluster

    # ======================================================
    # Step 3: absorb short outlier runs
    # A A A -1 -1 A A A -> A A A A A A A A
    # ======================================================

    cluster = df["cluster"].values.copy()

    i = 0
    n = len(cluster)

    while i < n:

        if cluster[i] != -1:
            i += 1
            continue

        start = i

        while i < n and cluster[i] == -1:
            i += 1

        end = i
        run_length = end - start

        left = cluster[start - 1] if start > 0 else None
        right = cluster[end] if end < n else None

        if (
            run_length < MAX_OUTLIER_RUN
            and left == right
            and left != -1
        ):
            cluster[start:end] = left

    df["cluster"] = cluster

    # ======================================================
    # Step 4: remove short-lived segments
    # ======================================================

    cluster = df["cluster"].values.copy()

    i = 0
    n = len(cluster)

    while i < n:

        if cluster[i] == -1:
            i += 1
            continue

        cl = cluster[i]
        start = i

        while i < n and cluster[i] == cl:
            i += 1

        end = i

        duration_days = (
            df["timestamp"].iloc[end - 1]
            - df["timestamp"].iloc[start]
        ).days

        if duration_days < MIN_SEGMENT_DAYS:
            cluster[start:end] = -1

    df["cluster"] = cluster

    # ======================================================
    # Step 5: re-evaluate stable outlier runs
    # low NSD variation -> likely stationary behaviour
    # ======================================================

    df["state"] = np.where(df["cluster"] == -1, -1, 0)

    state = df["state"].values.copy()
    nsd = df["nsd_scaled"].values

    i = 0
    n = len(state)

    while i < n:

        if state[i] != -1:
            i += 1
            continue

        start = i

        while i < n and state[i] == -1:
            i += 1

        end = i

        run_nsd = nsd[start:end]

        if len(run_nsd) == 0:
            continue

        delta = run_nsd.max() - run_nsd.min()

        if delta < OUTLIER_RUN_MAX_DELTA:
            state[start:end] = 0

    df["state"] = state

    complete.append(df)

# ==========================================================
# Merge and export all processed individuals
# ==========================================================

# Export consolidated spatial dataset
print("Exporting classified features...")
comp_df = pd.concat(complete)
# Convert to spatial GeoDataFrame before saving
final_gdf = gpd.GeoDataFrame(
    comp_df, 
    geometry=gpd.points_from_xy(comp_df.x, comp_df.y), 
    crs="EPSG:2056"
)
final_gdf.to_file(output_gpkg, driver="GPKG")
print("Clustering module execution complete.")