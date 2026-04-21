""" 

VerifyVault CAD Analyzer — FastAPI Application Entry Point 

""" 

import logging 

import time 

import uuid 

from contextlib import asynccontextmanager 

from pathlib import Path 

 

from fastapi import FastAPI, Request 

from fastapi.middleware.cors import CORSMiddleware 

from fastapi.middleware.gzip import GZipMiddleware 

from fastapi.responses import FileResponse, JSONResponse 

from fastapi.staticfiles import StaticFiles 

 

from config import settings 

from api.upload import router as upload_router 

from api.analyze import router as analyze_router 

from api.health import router as health_router 

from api.history import router as history_router 

from database.db import init_db 

 

# ── Logging ─────────────────────────────────────────────────────────────────── 

logging.basicConfig( 

    level=logging.DEBUG if settings.DEBUG else logging.INFO, 

    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s", 

    datefmt="%Y-%m-%dT%H:%M:%S", 

) 

logger = logging.getLogger(__name__) 

 

FRONTEND_DIR = Path(__file__).parent.parent / "frontend" 

 

 

# ── Lifespan ────────────────────────────────────────────────────────────────── 

@asynccontextmanager 

async def lifespan(app: FastAPI): 

    logger.info("Starting VerifyVault CAD Analyzer v%s ...", settings.APP_VERSION) 

    # Ensure upload dir exists 

    settings.UPLOAD_DIR.mkdir(parents=True, exist_ok=True) 

    # Init DB schema 

    await init_db() 

    logger.info("Startup complete. Upload dir: %s", settings.UPLOAD_DIR) 

    yield 

    logger.info("Shutting down VerifyVault.") 

 

 

# ── App ─────────────────────────────────────────────────────────────────────── 

app = FastAPI( 

    title="VerifyVault CAD Analyzer", 

    description="Real-time CAD manufacturability analysis and cost estimation", 

    version=settings.APP_VERSION, 

    docs_url="/docs" if settings.DEBUG else None, 

    redoc_url="/redoc" if settings.DEBUG else None, 

    lifespan=lifespan, 

) 

 

 

# ── Middleware ──────────────────────────────────────────────────────────────── 

app.add_middleware(GZipMiddleware, minimum_size=1000) 

app.add_middleware( 

    CORSMiddleware, 

    allow_origins=settings.ALLOWED_ORIGINS, 

    allow_credentials=True, 

    allow_methods=["GET", "POST", "OPTIONS"], 

    allow_headers=["*"], 

) 

 

 

@app.middleware("http") 

async def request_id_and_timing(request: Request, call_next): 

    """Attach X-Request-ID and X-Response-Time to every response.""" 

    request_id = str(uuid.uuid4())[:8] 

    request.state.request_id = request_id 

    start = time.perf_counter() 

    response = await call_next(request) 

    elapsed_ms = round((time.perf_counter() - start) * 1000, 1) 

    response.headers["X-Request-ID"] = request_id 

    response.headers["X-Response-Time"] = f"{elapsed_ms}ms" 

    if request.url.path.startswith("/api/"): 

        logger.info( 

            "%s %s → %d  (%sms) [%s]", 

            request.method, request.url.path, 

            response.status_code, elapsed_ms, request_id, 

        ) 

    return response 

 

 

# ── Routers ─────────────────────────────────────────────────────────────────── 

app.include_router(health_router, tags=["Health"]) 

app.include_router(upload_router,  prefix="/api", tags=["Upload"]) 

app.include_router(analyze_router, prefix="/api", tags=["Analysis"]) 

app.include_router(history_router, prefix="/api", tags=["History"]) 

 

 

# ── Frontend static serving ─────────────────────────────────────────────────── 

_static = FRONTEND_DIR / "static" 

if _static.exists(): 

    app.mount("/static", StaticFiles(directory=str(_static)), name="static") 

 

@app.get("/{full_path:path}", include_in_schema=False) 

async def serve_frontend(full_path: str): 

    """Serve the SPA index.html for all non-API paths.""" 

    candidate = FRONTEND_DIR / full_path 

    if candidate.is_file(): 

        return FileResponse(str(candidate)) 

    index = FRONTEND_DIR / "index.html" 

    if index.exists(): 

        return FileResponse(str(index)) 

    return JSONResponse({"detail": "Frontend not found."}, status_code=404) 