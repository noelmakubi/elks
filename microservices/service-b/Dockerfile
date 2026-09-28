FROM python:3.12-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY logging_utils.py app.py ./

# Log directory is bind-mounted from ./service-b/logs on the host.
ENV SERVICE_NAME=service-b \
    LOG_DIR=/var/log/service-b
RUN mkdir -p /var/log/service-b

EXPOSE 5002

CMD ["python", "app.py"]
