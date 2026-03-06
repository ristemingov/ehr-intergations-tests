FROM alpine:latest AS fetcher
ARG RELEASE

RUN apk update
RUN apk add git openssh-client

RUN mkdir -p /src/fhir-server
WORKDIR /src

RUN git clone https://github.com/microsoft/fhir-server.git

WORKDIR /src/fhir-server

RUN git fetch --tags --all
RUN git checkout tags/${RELEASE}


FROM mcr.microsoft.com/dotnet/sdk:9.0-alpine AS build

ARG FHIR_VERSION
ARG ASSEMBLY_VER

COPY --from=fetcher /src/fhir-server /repo
WORKDIR /repo

RUN dotnet restore ./src/Microsoft.Health.Fhir.${FHIR_VERSION}.Web/Microsoft.Health.Fhir.${FHIR_VERSION}.Web.csproj

# now copy over everything else and publish

RUN dotnet publish /repo/src/Microsoft.Health.Fhir.${FHIR_VERSION}.Web/Microsoft.Health.Fhir.${FHIR_VERSION}.Web.csproj \
    -c Release \
    -o "/build" \
    --no-restore \
    -p:AssemblyVersion="${ASSEMBLY_VER}" \
    -p:FileVersion="${ASSEMBLY_VER}" \
    -p:Version="${ASSEMBLY_VER}" \
    -f net9.0

FROM mcr.microsoft.com/dotnet/aspnet:9.0-alpine AS runtime

ARG FHIR_VERSION

RUN set -x && \
    # See https://www.abhith.net/blog/docker-sql-error-on-aspnet-core-alpine/
    apk add --no-cache icu-libs && \
    addgroup nonroot && \
    adduser -S -D -H -s /sbin/nologin -G nonroot -g nonroot nonroot

ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false \
    ASPNETCORE_URLS=http://+:8080

WORKDIR /app
COPY --from=build /build .

RUN ln -s "Microsoft.Health.Fhir.${FHIR_VERSION}.Web.dll" "Microsoft.Health.Fhir.Web.dll"

USER nonroot
EXPOSE 8080
ENTRYPOINT ["dotnet", "Microsoft.Health.Fhir.Web.dll"]