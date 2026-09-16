FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .
RUN mkdir -p /app/data

ENV PORT=3000
ENV DB_PATH=/app/data/keys.db

EXPOSE 3000
CMD ["python", "server.py"]
