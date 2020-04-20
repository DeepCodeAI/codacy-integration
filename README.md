# DeepCode's Codacy integration tool

This repository integrates DeepCode's [CLI](https://pypi.org/project/deepcode/) into a [Codacy Tool](https://github.com/codacy/codacy-example-tool/blob/master)

## Non-standard behaviours

Differntly from a standard Codacy integration, this tool doesn't instantiate a self-managed container with its own local static analyzer. It instead pulls the analysis results directly from the DeepCode's cloud instance which is constantly updating its model though machine learning algorithms. Due to the ever-changing nature of DeepCode's analysis, some parts of this tool don't match the Codacy specifications for tool integrations:
1. The tool needs network access to communicate with the DeepCode cloud instance (--net=none option not allowed).
2. To authenticate correctly in the cloud instance, a token must be provided at build time. 
3. No static pattern documentation can be provided inside the container.
4. The tool outputs additional information that would be normally provided by the static documentation.

## Building the docker

```bash
docker build -t deepcode_codacy --build-arg DEEPCODE_TOKEN=<deepcode_authentication_token> .
```

The authentication token is provided once at build time and is recorded for every execution.

## Running the docker

```bash
docker run -t \
--privileged=false \
--cap-drop=ALL \
--user=docker \
--rm=true \
-e TIMEOUT_SECONDS=<SECONDS-BEFORE-ANALYSIS-TIMEOUT> \
-v <PATH-TO-CODACYRC-FILE>:/.codacyrc:ro \
-v <PATH-TO-ANALYZED-DIRECTORY>:/src:ro \
deepcode_codacy
```

As discussed above, the tool needs to communicate with the DeepCode cloud instance and the `--net=none` option is not allowed (the analysis will timeout if provided).
If the `-e TIMEOUT_SECONDS=...` option is not provided or is not an integer, the standard timeout will be used instead (900 seconds).
If the `.codacyrc` file is not provided, all the files in the `/src` directory will be analyzed by default. Due to the lack of static patterns, the eventual patterns provided in the `.codacyrc` specification are ignored.
If the `/src` volume is not correctly mounted, the tool will fail.

### Optional paraneters
It is possible to add the `-e DEBUG=true` option to log debug strings to stdout (no log is kept otherwise). 

## Exit codes
The tool can exit with different codes, as per standard specification:
  * **0**: The tool executed successfully
  * **1**: An error occurred while running the tool
  * **2**: Analysis timeout

## Output format
For each file specified in the `.codacyrc` and not found in the `/src` directory, the tool prints a new line to stdout:
```json
{
  filename:<FILE-PATH-AS-SPECIFIED>,
  message:"could not parse the file"
}
```

For each suggestion reported by the analysis, the tool prints a new line to stdout:
```json
{
  filename:<FILE-PATH>,
  line:<LINE-NUMBER>,
  patternId:<ID_OF_THE_PATTERN>,
  message:<MESSAGE_OF_THE_PATTERN>,
  level:<LEVEL_OF_THE_PATTERN>,
  category:<CATEGORY_OF_THE_PATTERN>
}
```
The `level` and `category` which would normally be provided by the static pattern configuration, are instead printed by the tool whenever it finds an occurrence of the same pattern. Also, given the lack of static documentation, no additional fields like the `title` or `description` are provided on top of the `message`.
