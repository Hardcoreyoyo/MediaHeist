#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SigLIP 文字→圖片檢索小實驗（使用 hnswlib）
流程：
1. 查詢文字切段並做 embedding
2. 對 /frames 下所有圖片做 embedding
3. 用 hnswlib (HNSW graph) 以內積搜尋（向量先 L2 normalize ⇒ 內積 = cosine）
4. 輸出 Markdown

5. 執行
pipenv run python run_siglip_search.py > result.md
"""

import os, glob, re, json
import numpy as np
from PIL import Image
from tqdm import tqdm
import hnswlib

import torch
from transformers import SiglipProcessor, SiglipModel

# --------- 可調參數 ----------
# 根據執行位置，預設使用與此腳本同層的 `frames` 目錄；
# 亦可透過環境變數 IMAGE_DIR 覆寫。
IMAGE_DIR = os.getenv("IMAGE_DIR")  # 調整成你實際的圖片目錄
TEXT = """開發者宣布，經過兩個月在知識星球社群的內部測試與開發後，他自行研發的抓包軟體正式公開提供下載。他說明開發此軟體的初衷是為了解決 Wireshark 對新手不夠友善的問題，並整合一些企業級產品的實用功能，旨在降低網路封包分析的門檻。"""
MODEL_NAME = "google/siglip-base-patch16-512"

CHUNK_SENT_LEN = 60   # 中文粗切長度上限
TOP_K = 10
HNSW_M = 16           # HNSW graph 連結數（越大 recall 越好但建索引慢）
HNSW_EF_CONSTRUCT = 200
HNSW_EF_SEARCH = 64   # 查詢時探索節點數，越大越準但越慢

# --------- 工具函式 ----------
def zh_seg(text, max_len=60):
    """極簡中文斷句，先按標點，再合併到 max_len。"""
    sents = re.split(r'[。！？!?；;]\s*', text)
    chunks, buf = [], ""
    for s in sents:
        if not s.strip():
            continue
        if len(buf) + len(s) <= max_len:
            buf += (s + "。")
        else:
            if buf:
                chunks.append(buf)
            buf = s + "。"
    if buf:
        chunks.append(buf)
    return chunks

def l2_normalize(x: np.ndarray) -> np.ndarray:
    return x / np.linalg.norm(x, axis=-1, keepdims=True)

# --------- 1. 載入模型 ----------
device = "cuda" if torch.cuda.is_available() else "cpu"
processor = SiglipProcessor.from_pretrained(MODEL_NAME)
model = SiglipModel.from_pretrained(MODEL_NAME).to(device)
model.eval()

# --------- 2. 文字切段 & 向量 ----------
text_chunks = zh_seg(TEXT, CHUNK_SENT_LEN)
with torch.no_grad():
    inputs = processor(text=text_chunks, return_tensors="pt", padding=True, truncation=True).to(device)
    text_emb = model.get_text_features(**inputs).cpu().numpy()

text_emb = l2_normalize(text_emb)
query_vec = text_emb.mean(axis=0, keepdims=True).astype('float32')  # 簡單平均，可改 weighted / max pooling

# --------- 3. 圖片向量 ----------
img_paths = sorted(glob.glob(os.path.join(IMAGE_DIR, "*.*")))
img_feats = []
for p in tqdm(img_paths, desc="Embedding images"):
    try:
        img = Image.open(p).convert("RGB")
    except Exception as e:
        print("skip", p, e)
        continue
    with torch.no_grad():
        inputs = processor(images=img, return_tensors="pt").to(device)
        feat = model.get_image_features(**inputs).cpu().numpy()[0]
    img_feats.append(feat)

if not img_feats:
    raise RuntimeError("沒有可用的圖片向量，請檢查 IMAGE_DIR 是否正確。")

img_feats = np.stack(img_feats, axis=0)
img_feats = l2_normalize(img_feats).astype('float32')

# --------- 4. 建索引 & 搜尋 (hnswlib) ----------
d = img_feats.shape[1]
index = hnswlib.Index(space='ip', dim=d)  # 'ip' = inner product
index.init_index(max_elements=len(img_feats), ef_construction=HNSW_EF_CONSTRUCT, M=HNSW_M)
index.add_items(img_feats, np.arange(len(img_feats)))
index.set_ef(HNSW_EF_SEARCH)

labels, distances = index.knn_query(query_vec, k=TOP_K)
# hnswlib 的 distances 預設是越大越相似（因為內積），已經符合需求

# --------- 5. 輸出 Markdown ----------
result = []
for rank, (i, sc) in enumerate(zip(labels[0], distances[0]), start=1):
    result.append({"rank": rank, "path": img_paths[int(i)], "score": float(sc)})

md_lines = [f"# 搜尋結果 (Top {TOP_K})", ""]
for r in result:
    md_lines.append(f"**#{r['rank']}**  相似度: {r['score']:.4f}  路徑: `{r['path']}`")

print("\n".join(md_lines))

with open("siglip_search_result.json", "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
