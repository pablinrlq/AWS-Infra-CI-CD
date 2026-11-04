# wsi-api image - built by the CodeBuild project wsi-api-release
# PY_VERSION is passed by the build so the interpreter matches the one that compiled app.pyc
ARG PY_VERSION=3.12
FROM public.ecr.aws/docker/library/python:${PY_VERSION}-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /app
RUN pip install --no-cache-dir flask

COPY build/app.pyc /app/app.pyc

EXPOSE 80
# docker run <image>  -> starts the app.pyc process, no extra command needed
CMD ["python", "/app/app.pyc"]
