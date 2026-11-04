# wsi-api-repo

Python / Flask API (`GET /health`).

| Path | Purpose |
|------|---------|
| `src/app.py` | Application source |
| `appspec.yml` | CodeDeploy (wsi-api / dev-api, in-place) |
| `scripts/` | CodeDeploy lifecycle hooks |
| `buildspec.yml` | CodeBuild `wsi-api-build` (main): app.py -> app.pyc + Flask in `vendor/` + deployment bundle |
| `buildspec-release.yml` | CodeBuild `wsi-api-release` (release): app.pyc -> Docker image -> ECR `wsi-api-ecr:<YYMMDDhhmmss>` |
| `Dockerfile` | Image that runs `app.pyc` on `docker run` |

- Push to `main` -> CodePipeline `wsi-api-pipeline` (Source -> Build -> Deploy).
- Push to `release` -> CodeBuild `wsi-api-release` -> ECR.
- The instances have no internet access: Flask is downloaded by CodeBuild and shipped in the
  deployment bundle (`/opt/wsi-api/vendor`), python3 comes from the Amazon Linux repos through
  the S3 gateway endpoint.
