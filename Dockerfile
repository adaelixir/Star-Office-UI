FROM python:3.12-slim

WORKDIR /app

# Install Python deps first for layer caching
COPY backend/requirements.txt backend/requirements.txt
RUN pip install --no-cache-dir -r backend/requirements.txt

# Copy all project files
COPY . .

# Prepare default data files if missing (will be overridden by volume mounts)
RUN cp -n state.sample.json state.json 2>/dev/null || true && \
    cp -n join-keys.sample.json join-keys.json 2>/dev/null || true

EXPOSE 19000

ENV STAR_OFFICE_ENV=production
ENV STAR_BACKEND_PORT=19000

CMD ["python", "backend/app.py"]
