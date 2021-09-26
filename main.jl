function get_build_number(pr_number::AbstractString;
                          organization_slug::AbstractString, pipeline_slug::AbstractString)
    _pr_number = strip(pr_number)
    !isempty(_pr_number)                  || throw(ArgumentError("You must provide a valid pull request number"))
    occursin(r"^[\d][\d]*?$", _pr_number) || throw(ArgumentError("You must provide a valid pull request number"))
    builds_per_page = 100
    max_pages = 100
    for page_number = 1:max_pages
        url = string(
            "https://api.buildkite.com/v2/",
            "organizations/$(organization_slug)/",
            "pipelines/$(pipeline_slug)/",
            "builds?per_page=$(builds_per_page)&page=$(page_number)",
        )
        cmd_string = string(
            "curl -X GET -H \"Authorization: Bearer $(ENV["BUILDKITE_API_TOKEN"])\" \"$(url)\"",
            "| ",
            "jq '[.[] | {pr: .pull_request.id, id: .id, number: .number}]' ",
            "| ",
            "jq '.[] | select(.pr == \"$(_pr_number)\") | .number'",
        )
        cmd = `bash -c $(cmd_string)`
        sleep(0.1) # helps us stay under the Buildkite API rate limits
        str = read(cmd, String)
        lines = strip.(strip.(strip.(split(strip(str), '\n')), Ref('"')))
        filter!(x -> !isempty(x), lines)
        if !isempty(lines)
            build_number = convert(String, strip(lines[1]))::String
            return build_number
        end # if
    end # for
    msg = string(
        "I tried $(max_pages) pages ",
        "(with $(builds_per_page) builds per page), ",
        "but I could not find any Buildkite builds for ",
        "GitHub pull request $(pr_number).",
    )
    throw(ErrorException(msg))
end

function get_failed_job_ids(build_number::AbstractString;
                            organization_slug::AbstractString, pipeline_slug::AbstractString)
    url = string(
        "https://api.buildkite.com/v2/",
        "organizations/$(organization_slug)/",
        "pipelines/$(pipeline_slug)/",
        "builds/$(build_number)",
    )
    cmd_string_1 = string(
        "curl -X GET -H \"Authorization: Bearer $(ENV["BUILDKITE_API_TOKEN"])\" \"$(url)\"",
        "| ",
        "jq '[.jobs | . | .[] | {id: .id, state: .state}]' ",
        "| ",
        "jq '[.[] | select((.state == \"failed\") or (.state == \"errored\"))]'",
    )
    cmd_string_2 = string(cmd_string_1, "| ", "jq '.[] .id'")
    cmd_1 = `bash -c $(cmd_string_1)`
    cmd_2 = `bash -c $(cmd_string_2)`
    sleep(0.1) # helps us stay under the Buildkite API rate limits
    run(cmd_1) # print the output to the log, for debugging purposes
    sleep(0.1) # helps us stay under the Buildkite API rate limits
    str = read(cmd_2, String)
    lines = strip.(strip.(strip.(split(strip(str), '\n')), Ref('"')))
    filter!(x -> !isempty(x), lines)
    failed_job_ids = convert(Vector{String}, lines)
    return failed_job_ids
end

function retry_job(build_number::AbstractString, job_id::AbstractString;
                   organization_slug::AbstractString, pipeline_slug::AbstractString)
    url = string(
        "https://api.buildkite.com/v2/",
        "organizations/$(organization_slug)/",
        "pipelines/$(pipeline_slug)/",
        "builds/$(build_number)/",
        "jobs/$(job_id)/retry",
    )
    cmd_string = string(
        "curl -X PUT -H \"Authorization: Bearer $(ENV["BUILDKITE_API_TOKEN"])\" \"$(url)\"",
    )
    cmd = `bash -c $(cmd_string)`
    sleep(0.1) # helps us stay under the Buildkite API rate limits
    run(cmd)
    return nothing
end

function retry_jobs(build_number::AbstractString, job_ids::AbstractVector{<:AbstractString};
                    organization_slug::AbstractString, pipeline_slug::AbstractString,)
    if isempty(job_ids)
        @info "There are no jobs to retry."
    end
    num_jobs = length(job_ids)
    for (i, job_id) in enumerate(job_ids)
        @info "$(i) of $(num_jobs). Attempting to retry job: $(job_id)"
        retry_job(build_number, job_id; organization_slug, pipeline_slug)
    end
    return nothing
end

function main(pr_number::AbstractString;
              organization_slug::AbstractString, pipeline_slug::AbstractString)
    @info "The Buildkite organization is $(organization_slug)"
    @info "The Buildkite pipeline is $(pipeline_slug)"
    @info "The GitHub pull request number is $(pr_number)"
    build_number = get_build_number(pr_number; organization_slug, pipeline_slug)
    @info "The build number is $(build_number)"
    failed_job_ids = get_failed_job_ids(build_number; organization_slug, pipeline_slug)
    @info "There are $(length(failed_job_ids)) failed jobs." failed_job_ids
    retry_jobs(build_number, failed_job_ids; organization_slug, pipeline_slug)
    return nothing
end

const pr_number         = ENV["PR_NUMBER"]
const organization_slug = ENV["BUILDKITE_ORGANIZATION_SLUG"]
const pipeline_slug     = ENV["BUILDKITE_PIPELINE_SLUG"]

main(pr_number; organization_slug, pipeline_slug)
