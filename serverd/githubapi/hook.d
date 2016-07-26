module githubapi.hook;

import log;
import mysql_client;
import utils;

import model.project;
import model.pull;

import std.algorithm;
import std.conv;
import std.json;
import std.range;

bool parseAndReturn(string str, ref JSONValue jv)
{
    try
    {
        jv = parseJSON(str);
    }
    catch (JSONException e)
    {
        writelog("  error parsing github json: %s\n", e.toString);
        return false;
    }

    if (jv.type != JSON_TYPE.OBJECT)
    {
        writelog("  json parsed, but isn't an object: %s", str);
        return false;
    }

    return true;
}

bool processPush(const ref JSONValue jv)
{
    const(JSONValue)* refname = "ref" in jv.object;
    const(JSONValue)* repo    = "repository" in jv.object;

    // doesn't look like a Push request, bail out
    if (!refname || !repo) return false;

    const(JSONValue)* owner    = "owner" in repo.object;
    const(JSONValue)* reponame = "name" in repo.object;

    if (!owner || !reponame)
    {
        writelog("  missing repo.owner or repo.name, invalid push?");
        return false;
    }

    owner = "name" in owner.object;

    if (!owner)
    {
        writelog("  missing repo.owner.name, invalid push?");
        return false;
    }

    string branch = refname.str;
    if (!branch.startsWith("refs/heads/"))
    {
        writelog("  unexpected ref format, expecting refs/heads/<branchname>, got: %s", branch);
        return false;
    }
    branch = branch[11 .. $];

    Results r = mysql.query(text("select p.id "
                  "from projects p, repositories r, project_repositories pr "
                  "where p.id = pr.project_id and pr.repository_id = r.id and "
                  "r.owner = \"", sql_quote(owner.str), "\" and r.name = \"", reponame.str, "\" and r.ref = \"", sql_quote(branch), "\""));

    if (r.empty)
    {
        writelog ("  no project found for '%s/%s/%s'", owner.str, reponame.str, branch);
        return false;
    }
    string projectid = r.front[0];

    // invalidate obsoleted test_runs
    mysql.query(text("update test_runs set deleted = true where start_time < (select post_time from github_posts order by id desc limit 1) and deleted = false and project_id = ", projectid));

    // invalidate obsoleted pull_test_runs
    // TODO: merge these two queries into one query with nesting
    r = mysql.query(text("select r.id "
                  "from projects p, repositories r, project_repositories pr "
                  "where p.id = pr.project_id and "
                  "pr.repository_id = r.id and "
                  "p.id = ", projectid));

    string query = "update pull_test_runs set deleted = true where start_time < (select post_time from github_posts order by id desc limit 1) and deleted = false and g_p_id in (select id from github_pulls where repo_id in (";
    bool first = true;
    foreach(row; r)
    {
        if (first)
            first = false;
        else
            query ~= ", ";
        query ~= row[0];
    }
    query ~= "))";

    mysql.query(query);

    return true;
}

bool processPull(const ref JSONValue jv)
{
    const(JSONValue)* action       = "action" in jv.object;
    const(JSONValue)* number       = "number" in jv.object;
    const(JSONValue)* pull_request = "pull_request" in jv.object;

    // doesn't look like a Push request, bail out
    if (!action || !number || !pull_request) return false;

    const(JSONValue)* base           = "base"  in pull_request.object;
    const(JSONValue)* base_repo      = "repo"  in base.object;
    const(JSONValue)* base_repo_name = "name"  in base_repo.object;

    const(JSONValue)* base_user      = "user"  in base.object;
    const(JSONValue)* base_ref       = "ref"   in base.object;
    const(JSONValue)* owner          = "login" in base_user.object;

    // TODO: a single pull may affect multiple projects
    Project proj = loadProject(owner.str, base_repo_name.str, base_ref.str);
    Repository repo = proj.getRepositoryByName(base_repo_name.str);

    Pull github_pull = makePullFromJson(*pull_request, repo);
    if (!github_pull) return false;

    Pull db_pull = loadPull(repo.id, number.integer);

// TODO: figureout how to make this work cleanly here.. currently using github's updated_at field which
//       updates more frequently than when commits are made.  Luckily, this hook is only supposed to
//       be called when a commit has been made, so it's roughly the same.
//
//    if (db_pull.head_sha == github_pull.head_sha)
//        github_pull.head_date = db_pull.head_date;
//    else
//    {
//        string date = github.loadCommitDateFromGithub(repo.owner, repo.name, github_pull.head_sha);
//        if (!date) return false;
//        github_pull.head_date = SysTime.fromISOExtString(date, UTC());;
//    }

    if (db_pull)
        updatePull(repo, db_pull, github_pull);
    else
        newPull(repo, github_pull);

    return true;
}

void run(const ref string[string] hash, const ref string[string] userhash, Appender!string outstr)
{
    outstr.put("Content-type: text/plain\n\n");

    string raddr = lookup(hash, "REMOTE_ADDR");
    string eventname = lookup(hash, "HTTP_X_GITHUB_EVENT");  // TODO: add to schema and store
    string eventid = lookup(hash, "HTTP_X_GITHUB_DELIVERY"); // TODO: add to schema and store
    string bodytext = lookup(userhash, "REQUEST_BODY");

    // TODO: add auth check

    mysql.query(text("insert into github_posts (id, post_time, body) values (null, now(), \"", sql_quote(bodytext), "\")"));
    Results r = mysql.query("select last_insert_id()");
    string liid = r.front[0];
    //formattedWrite(outstr, "%s\n", liid);

    if (!eventname)
    {
        writelog("  missing X-GitHub-Event header, ignoring");
        return;
    }

    JSONValue jv;
    if (!parseAndReturn(bodytext, jv)) return;

    bool rc = true;
    switch(eventname)
    {
        case "push":         rc = processPush(jv); break;
        case "pull_request": rc = processPull(jv); break;
        default:             writelog("  unrecognized event, id: %s", liid); break;
    }

    if (!rc)
        writelog("  processing of event id %s failed", liid);
}

