FROM python:3.12-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY logging_utils.py app.py ./

# Log directory is bind-mounted from ./service-a/logs on the host.
ENV SERVICE_NAME=service-a \
    LOG_DIR=/var/log/service-a
RUN mkdir -p /var/log/service-a

EXPOSE 5001

CMD ["python", "app.py"]
