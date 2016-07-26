module loggedin.approve_pull_requester;

import std.array;
import std.conv;
import std.format;

import mysql_client;
import utils;
import validate;

bool validateInput(ref string projectid, ref string pull_userid, Appender!string outstr)
{
    if (!validate_id(projectid, "projectit", outstr))
        return false;
    if (!validate_id(pull_userid, "userid", outstr))
        return false;

    return true;
}

bool validateCanApprove(string userid, Appender!string outstr)
{
    Results r = mysql.query(text("select pull_approver from github_users where id = ", userid));
    sqlrow row = getExactlyOneRow(r);
    if (!row || row[0] == "")
    {
        formattedWrite(outstr, "error, user not approved to approve new pullers");
        return false;
    }

    return true;
}

void run(const ref string[string] hash, const ref string[string] userhash, Appender!string outstr)
{
    auto valout = appender!string;

    string access_token;
    string userid;
    string username;
    if (!validateAuthenticated(userhash, access_token, userid, username, valout))
    {
Lerror:
        outstr.put("Content-type: text/plain\n\n");
        outstr.put(valout.data);
        return;
    }

    string projectid = lookup(userhash, "projectid");
    string pull_userid = lookup(userhash, "userid");

    if (!validateInput(projectid, pull_userid, valout))
        goto Lerror;

    if (!validateCanApprove(userid, valout))
        goto Lerror;

    mysql.query(text("update github_users set pull_approver = ", userid, " where id = ", pull_userid));

    outstr.put(text("Location: ", getURLProtocol(hash) , "://", lookup(hash, "SERVER_NAME"), "/pulls.ghtml?projectid=", projectid));
    outstr.put("\n\n");
}

