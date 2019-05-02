# Plugin for Foswiki - The Free and Open Source Wiki, http://foswiki.org/
#
# Copyright (C) 2015-2019 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html
#
###############################################################################
package Foswiki::Plugins::BlogPlugin::ImportWordPress;

use strict;
use warnings;
use Error qw(:try);
use Foswiki::Func ();
use Foswiki::Meta ();
use XML::LibXML qw(:libxml);
use Encode ();
use Foswiki::Plugins::ImagePlugin();
use URI ();

#use Data::Dump qw(dump);
use constant TRACE => 0;
use constant DRY => 0;

###############################################################################
sub new {
  my $class = shift;
  my $session = shift;

  return bless({
    session => $session,
    knownCategories => {},
    downloadables => [],
    dry => DRY,
    @_
  }, $class);
}

###############################################################################
sub writeDebug {
  return unless TRACE;

  print STDERR "ImportWordPress - ".$_[0]."\n";
}

###############################################################################
sub import {
  my ($this, $subject, $verb, $response) = @_;

  my $request = $this->{session}{request};

  $this->{targetWeb} = $request->param("target");
  throw Error::Simple("no target web specified")
    unless $this->{targetWeb};

  $this->{doOverride} = Foswiki::Func::isTrue($request->param("override"), 0);

  $this->{templateWeb} = $request->param("template") || '_BlogTemplate';
  throw Error::Simple("tempalte web $this->{templateWeb} does not exists")
    unless Foswiki::Func::webExists($this->{templateWeb});

  $this->{file} = $request->param("file");
  throw Error::Simple("no xml file specified")
    unless $this->{file};

  throw Error::Simple("file $this->{file} not found")
    unless -e $this->{file};

  $this->{post_id} = $request->param("id");

  $this->{dry} = Foswiki::Func::isTrue($request->param("dry"), DRY);

  writeDebug("post_id=$this->{post_id}") if defined $this->{post_id};
  #writeDebug("targetWeb=$this->{targetWeb}");
  #writeDebug("file=$this->{file}");

  my $doc = $this->parseFile();

  $this->createTargetWeb($doc) unless Foswiki::Func::webExists($this->{targetWeb});
  $this->importCategories($doc);
  $this->importBlogEntries($doc);
  $this->mirrorDownloadables();
}

###############################################################################
sub createRedirectMap {
  my ($this, $subject, $verb, $response) = @_;

  my $request = $this->{session}{request};

  $this->{targetWeb} = $request->param("target");
  throw Error::Simple("no target web specified")
    unless $this->{targetWeb};

  $this->{file} = $request->param("file");
  throw Error::Simple("no xml file specified")
    unless $this->{file};

  throw Error::Simple("file $this->{file} not found")
    unless -e $this->{file};

  $this->{post_id} = $request->param("id");

  my $format = $request->param("format") || 'apache';
  throw Error::Simple("unknown output format")
    unless $format =~ /^(nginx|apache)$/;

  my $viewUrlPath = $request->param("path");
  my $origUrlPath = $Foswiki::cfg{ScriptUrlPaths}{view};
  $Foswiki::cfg{ScriptUrlPaths}{view} = $viewUrlPath if defined $viewUrlPath;

  #writeDebug("post_id=$this->{post_id}") if defined $this->{post_id};
  #writeDebug("targetWeb=$this->{targetWeb}");
  #writeDebug("file=$this->{file}");

  my $doc = $this->parseFile();
  my $index = 0;

  foreach my $node ($doc->findnodes("//item")) {
    my $posting = $this->parseNode($node);
    my @cats = ();
    my @tags = ();

    next if defined($this->{post_id}) && $posting->{wp}{post_id} ne $this->{post_id};
    if ($posting->{wp}{post_type} ne 'post') {
      writeDebug("... skipping $posting->{title}, post_id=$posting->{wp}{post_id} type=$posting->{wp}{post_type}");
      next;
    }

    next unless $posting->{wp}{status} eq 'publish';

    my $title = $posting->{title};
    my $link = $posting->{link};

    my $topic = _wikify($title);
    my $oldPath = URI->new($link)->path;
    my $newPath = URI->new(Foswiki::Func::getScriptUrlPath($this->{targetWeb}, $topic, "view"))->path;


    if ($format eq 'nginx') {
      $oldPath =~ s/\/?$/\/?/;
      print "~*". $oldPath . " " . $newPath . ";\n";
    } else {
      print "RewriteRule " . $oldPath . " " . $newPath . " [R=301,L]\n";
    }

    $index++;
  }

  $Foswiki::cfg{ScriptUrlPaths}{view} = $origUrlPath if defined $viewUrlPath;
 
  writeDebug("found $index redirects"); 
}


###############################################################################
sub parseFile  {
  my ($this, $file) = @_;

  $file ||= $this->{file};

  unless ($this->{xmlParser}) {
    $this->{xmlParser} = XML::LibXML->new;
  }

  return $this->{xmlParser}->load_xml(
    location => $file  
  );
}

###############################################################################
sub createTargetWeb {
  my ($this, $doc) = @_;

  my $webSummary = $doc->findvalue("//channel/description");

  writeDebug("creating web $this->{targetWeb}, summary=$webSummary");

  return if $this->{dry};

  my $obj = new Foswiki::Meta($this->{session}, $this->{targetWeb});

  $obj->populateNewWeb(
    $this->{templateWeb},
    {
      WEBSUMMARY => $webSummary,
      NOAUTOLINK => "on",
    }
  );
}

###############################################################################
sub importCategories {
  my ($this, $doc) = @_;

  #writeDebug("called importCategories");

  my $index = 0;
  foreach my $node ($doc->findnodes("//channel/wp:category")) {
    if ($this->createCategory($this->parseNode($node))) {
      $index++;
    }
  }

  writeDebug("created $index categories");
}

###############################################################################
sub createCategory {
  my ($this, $hash) = @_;

  my $topicTitle = $hash->{wp}{cat_name};
  
  return 0 if $topicTitle eq 'Uncategorized';
  return 0 if $this->{knownCategories}{$topicTitle};

  my $summary = $hash->{wp}{category_description} || '';
  my $topic = _wikify($topicTitle);
  $topic =~ s/^(.+)(Category)?$/$1/g;
  $topic .= "Category";

  $this->{knownCategories}{$topicTitle} = $topic;


  if (!$this->{doOverride} && Foswiki::Func::topicExists($this->{targetWeb}, $topic)) {
    writeDebug("category $topic already exists");
    return;
  }

  writeDebug("creating category '$topicTitle' at $this->{targetWeb}.$topic, summary=$summary");

  my $obj = new Foswiki::Meta($this->{session}, $this->{targetWeb}, $topic, "");

  $obj->putKeyed('FORM', {name => "Applications.ClassificationApp.Category"});

  my @fields = ();

  push @fields, {
    name => "TopicType",
    title => "TopicType",
    value => "Category, CategorizedTopic, WikiTopic",
  };

  push @fields, {
    name => "TopicTitle",
    title => "<nop>TopicTitle",
    value => $topicTitle,
  };

  push @fields, {
    name => "Summary",
    title => "Summary",
    value => $summary,
  };

  $obj->putAll("FIELD", @fields);


  $obj->save unless $this->{dry};

  return 1;
}

###############################################################################
sub importBlogEntries {
  my ($this, $doc) = @_;

  my $index = 0;
  #writeDebug("called importBlogEntries");

  foreach my $node ($doc->findnodes("//item")) {
    my $posting = $this->parseNode($node);
    my @cats = ();
    my @tags = ();

    if ($posting->{"category"}) {
      my %cats = ();
      
      if (ref($posting->{"category"})) {
        %cats = map {$_ => 1} @{$posting->{"category"}};
      } else {
        %cats = (
          $posting->{"category"} => 1,
        );
      }
      foreach my $cat (grep {!/Uncategorized/} keys %cats) {
        if ($this->{knownCategories}{$cat}) {
          push @cats, $this->{knownCategories}{$cat};
        } else {
          push @tags, $cat;
        }
      }
    }

    $posting->{category} = \@cats;
    $posting->{tags} = \@tags;

    next if defined($this->{post_id}) && $posting->{wp}{post_id} ne $this->{post_id};
    if ($posting->{wp}{post_type} ne 'post') {
      writeDebug("... skipping $posting->{title}, post_id=$posting->{wp}{post_id} type=$posting->{wp}{post_type}");
      next;
    }

    $this->createBlogEntry($posting);
    $index++;
  }
 
  writeDebug("created $index blog entries"); 
}

###############################################################################
sub createBlogEntry {
  my ($this, $hash) = @_;

  my $topicTitle = $hash->{title};
  my $topic = _wikify($topicTitle);
  $this->{targetTopic} = $topic;

  if (Foswiki::Func::topicExists($this->{targetWeb}, $topic)) {
    my $obj = new Foswiki::Meta($this->{session}, $this->{targetWeb}, $topic);
    #writeDebug("... found $this->{targetWeb}.$topic ... removing it first");
    $obj->removeFromStore unless $this->{dry};
  }

  my $date = $hash->{pubDate};
  $date = Foswiki::Time::parseTime($date, 1);

  my @tags = @{$hash->{tags}};
  my @cats = @{$hash->{category}};
  my $state = $hash->{wp}{status} eq 'publish' ? 'published':'unpublished';
  my $author = $hash->{dc}{creator};
  my $commentState = $hash->{wp}{comment_status};

  #$this->{linkMapping}{$topic} = $hash->{link};

  my $html = $hash->{content}{encoded};
  unless (defined $html) {
    writeDebug("skipping post_id ".$hash->{wp}{post_id}." ... no content");
    return;
  }

  writeDebug("creating BlogEntry $this->{targetWeb}.$topic for post_id ".$hash->{wp}{post_id});

  my $text = $this->HTML2TML($html);

  $text .= "\n<!-- >post_id = $hash->{wp}{post_id}, link = $hash->{link} -->\n"
    if TRACE;

  #writeDebug("topicTitle=$topicTitle");
  #writeDebug("topic=$topic");
  #writeDebug("author=$author");
  #writeDebug("tags=@tags");
  #writeDebug("cats=".join(", ", sort @cats));
  #writeDebug("state=$state");
  #writeDebug("commentState=$commentState");

  my $obj = new Foswiki::Meta($this->{session}, $this->{targetWeb}, $topic, $text);
  $obj->putKeyed('FORM', { name => "Applications.BlogApp.BlogEntry" });

  my @fields = ();

  push @fields, {
    name => "TopicType",
    title => "TopicType",
    value => "BlogEntry, SeoTopic, ClassifiedTopic, CategorizedTopic, TaggedTopic, WikiTopic",
  };

  push @fields, {
    name => "TopicTitle",
    title => "<nop>TopicTitle",
    value => $topicTitle,
  };

  push @fields, {
    name => "Tag",
    title => "Tag",
    value => join(", ", sort @tags),
  };


  push @fields, {
    name => "Category",
    title => "Category",
    value => join(", ", sort @cats),
  };

  push @fields, {
    name => "State",
    title => "State",
    value => $state,
  };

  if ($state ne 'published') {
    $obj->putAll("PREFERENCE", 
      {
        name => "ALLOWTOPICVIEW", 
        title => "ALLOWTOPICVIEW", 
        type => "Set", 
        value => "BlogAuthorGroup, $author"
      }, 
      {
        name => "PERMSET_VIEW", 
        title => "PERMSET_VIEW", 
        type => "Local", 
        value => "details"
      }, 
      {
        name => "PERMSET_VIEW_DETAILS", 
        title => "PERMSET_VIEW_DETAILS", 
        type => "Local", 
        value => "BlogAuthorGroup, $author"
      }
    );
  }

  $obj->putKeyed("PREFERENCE", 
    { 
      name => "DISPLAYCOMMENTS", 
      title => "DISPLAYCOMMENTS", 
      type => "Local", 
      value => "on",
    }
  );

  $obj->putKeyed("PREFERENCE", 
    { 
      name => "COMMENTSTATE", 
      title => "COMMENTSTATE", 
      type => "Local", 
      value => $commentState,
    }
  );

  push @fields, {
    name => 'Author',
    title => 'Author',
    value =>  $author
  };

  $obj->putAll("FIELD", @fields);

  if ($hash->{wp} && $hash->{wp}{comment}) {
    my $comments;
    if (ref($hash->{wp}{comment}) eq 'ARRAY') {
      $comments = $hash->{wp}{comment};
    } else {
      push @$comments, $hash->{wp}{comment};
    }
    foreach my $comment (@$comments) {
      $comment = $comment->{wp};
      my $state = $comment->{comment_approved} eq '1'?'approved':'unapproved';
      next if $state eq 'unapproved' && $commentState eq 'closed';

      #print STDERR "comment=".dump($comment)."\n";

      my $text = $comment->{comment_content};
      $text = $this->HTML2TML($text);
      $text =~ s/^\s+|\s+$//g;
      $text = Encode::encode($Foswiki::cfg{Site}{CharSet}, $text);
    
      $obj->putKeyed(
        'COMMENT',
        {
          author => $comment->{comment_author},
          author_url => $comment->{comment_author_url},
          state => $state,
          date => Foswiki::Time::parseTime($comment->{comment_date}, 1),
          name => $comment->{comment_id},
          text => $text,
          title => "",
        }
      );
    }
  }
  #print STDERR "topic=\n".$obj->getEmbeddedStoreForm."\n";

  unless ($this->{dry}) {
    # save it once, and then ...
    try {
      $obj->save(forcedate => $date, author => $author);
    } catch Error::Simple with {
      my $error = shift;
      print STDERR "ERROR: $error\n";
    };
   
    # ... force a second revision to freeze the create time and author
    try {
      $obj->save(forcedate => $date, author => $author, forcenewrevision => 1);
    } catch Error::Simple with {
      my $error = shift;
      print STDERR "ERROR: $error\n";
    };
  }
}

###############################################################################
sub _wikify {
  my $string = shift;

  $string = _transliterate($string);

  my $wikiWord = "";

  # first, try without forcing each part to be lowercase
  foreach my $part (split(/[^$Foswiki::regex{mixedAlphaNum}]/, $string)) {
    $wikiWord .= ucfirst($part);
  }

  # if it isn't a valid WikiWord then try more agressively to create a proper wikiWord
  unless (Foswiki::Func::isValidWikiWord($wikiWord)) {
    $wikiWord = '';
    foreach my $part (split(/[^$Foswiki::regex{mixedAlphaNum}]/, $string)) {
      $wikiWord .= ucfirst(lc($part));
    }
  }

  return $wikiWord;
}

###############################################################################
sub _transliterate {
  my $string = shift;

  if ($Foswiki::cfg{Site}{CharSet} =~ /^utf-?8$/i) {
    $string =~ s/\xc3\xa0/a/g;    # a grave
    $string =~ s/\xc3\xa1/a/g;    # a acute
    $string =~ s/\xc3\xa2/a/g;    # a circumflex
    $string =~ s/\xc3\xa3/a/g;    # a tilde
    $string =~ s/\xc3\xa4/ae/g;   # a uml
    $string =~ s/\xc3\xa5/a/g;    # a ring above
    $string =~ s/\xc3\xa6/ae/g;   # ae
    $string =~ s/\xc4\x85/a/g;    # a ogonek

    $string =~ s/\xc3\x80/A/g;    # A grave
    $string =~ s/\xc3\x81/A/g;    # A acute
    $string =~ s/\xc3\x82/A/g;    # A circumflex
    $string =~ s/\xc3\x83/A/g;    # A tilde
    $string =~ s/\xc3\x84/Ae/g;   # A uml
    $string =~ s/\xc3\x85/A/g;    # A ring above
    $string =~ s/\xc3\x86/AE/g;   # AE
    $string =~ s/\xc4\x84/A/g;    # A ogonek

    $string =~ s/\xc3\xa7/c/g;    # c cedille
    $string =~ s/\xc4\x87/c/g;    # c acute
    $string =~ s/\xc4\x8d/c/g;    # c caron
    $string =~ s/\xc3\x87/C/g;    # C cedille
    $string =~ s/\xc4\x86/C/g;    # C acute
    $string =~ s/\xc4\x8c/C/g;    # C caron

    $string =~ s/\xc4\x8f/d/g;    # d caron
    $string =~ s/\xc4\x8e/D/g;    # D caron

    $string =~ s/\xc3\xa8/e/g;    # e grave
    $string =~ s/\xc3\xa9/e/g;    # e acute
    $string =~ s/\xc3\xaa/e/g;    # e circumflex
    $string =~ s/\xc3\xab/e/g;    # e uml
    $string =~ s/\xc4\x9b/e/g;    # e caron

    $string =~ s/\xc4\x99/e/g;    # e ogonek
    $string =~ s/\xc4\x98/E/g;    # E ogonek
    $string =~ s/\xc4\x9a/E/g;    # E caron

    $string =~ s/\xc3\xb2/o/g;    # o grave
    $string =~ s/\xc3\xb3/o/g;    # o acute
    $string =~ s/\xc3\xb4/o/g;    # o circumflex
    $string =~ s/\xc3\xb5/o/g;    # o tilde
    $string =~ s/\xc3\xb6/oe/g;   # o uml
    $string =~ s/\xc3\xb8/o/g;    # o stroke

    $string =~ s/\xc3\xb3/o/g;    # o acute
    $string =~ s/\xc3\x93/O/g;    # O acute

    $string =~ s/\xc3\x92/O/g;    # O grave
    $string =~ s/\xc3\x93/O/g;    # O acute
    $string =~ s/\xc3\x94/O/g;    # O circumflex
    $string =~ s/\xc3\x95/O/g;    # O tilde
    $string =~ s/\xc3\x96/Oe/g;   # O uml

    $string =~ s/\xc3\xb9/u/g;    # u grave
    $string =~ s/\xc3\xba/u/g;    # u acute
    $string =~ s/\xc3\xbb/u/g;    # u circumflex
    $string =~ s/\xc3\xbc/ue/g;   # u uml
    $string =~ s/\xc5\xaf/u/g;    # u ring above

    $string =~ s/\xc3\x99/U/g;    # U grave
    $string =~ s/\xc3\x9a/U/g;    # U acute
    $string =~ s/\xc3\x9b/U/g;    # U circumflex
    $string =~ s/\xc3\x9c/Ue/g;   # U uml
    $string =~ s/\xc5\xae/U/g;    # U ring above

    $string =~ s/\xc5\x99/r/g;    # r caron
    $string =~ s/\xc5\x98/R/g;    # R caron

    $string =~ s/\xc3\x9f/ss/g;   # sharp s
    $string =~ s/\xc5\x9b/s/g;    # s acute
    $string =~ s/\xc5\xa1/s/g;    # s caron
    $string =~ s/\xc5\x9a/S/g;    # S acute
    $string =~ s/\xc5\xa0/S/g;    # S caron

    $string =~ s/\xc5\xa5/t/g;    # t caron
    $string =~ s/\xc5\xa4/T/g;    # T caron

    $string =~ s/\xc3\xb1/n/g;    # n tilde
    $string =~ s/\xc5\x84/n/g;    # n acute
    $string =~ s/\xc5\x88/n/g;    # n caron
    $string =~ s/\xc5\x83/N/g;    # N acute
    $string =~ s/\xc5\x87/N/g;    # N caron

    $string =~ s/\xc3\xbe/y/g;    # y acute
    $string =~ s/\xc3\xbf/y/g;    # y uml

    $string =~ s/\xc3\xac/i/g;    # i grave
    $string =~ s/\xc3\xab/i/g;    # i acute
    $string =~ s/\xc3\xac/i/g;    # i circumflex
    $string =~ s/\xc3\xad/i/g;    # i uml

    $string =~ s/\xc5\x82/l/g;    # l stroke
    $string =~ s/\xc4\xbe/l/g;    # l caron
    $string =~ s/\xc5\x81/L/g;    # L stroke
    $string =~ s/\xc4\xbd/L/g;    # L caron

    $string =~ s/\xc5\xba/z/g;    # z acute
    $string =~ s/\xc5\xb9/Z/g;    # Z acute
    $string =~ s/\xc5\xbc/z/g;    # z dot
    $string =~ s/\xc5\xbb/Z/g;    # Z dot
    $string =~ s/\xc5\xbe/z/g;    # z caron
    $string =~ s/\xc5\xbd/Z/g;    # Z caron
  } else {
    $string =~ s/\xe0/a/g;        # a grave
    $string =~ s/\xe1/a/g;        # a acute
    $string =~ s/\xe2/a/g;        # a circumflex
    $string =~ s/\xe3/a/g;        # a tilde
    $string =~ s/\xe4/ae/g;       # a uml
    $string =~ s/\xe5/a/g;        # a ring above
    $string =~ s/\xe6/ae/g;       # ae
    $string =~ s/\x01\x05/a/g;    # a ogonek

    $string =~ s/\xc0/A/g;        # A grave
    $string =~ s/\xc1/A/g;        # A acute
    $string =~ s/\xc2/A/g;        # A circumflex
    $string =~ s/\xc3/A/g;        # A tilde
    $string =~ s/\xc4/Ae/g;       # A uml
    $string =~ s/\xc5/A/g;        # A ring above
    $string =~ s/\xc6/AE/g;       # AE
    $string =~ s/\x01\x04/A/g;    # A ogonek

    $string =~ s/\xe7/c/g;        # c cedille
    $string =~ s/\x01\x07/C/g;    # c acute
    $string =~ s/\xc7/C/g;        # C cedille
    $string =~ s/\x01\x06/c/g;    # C acute

    $string =~ s/\xe8/e/g;        # e grave
    $string =~ s/\xe9/e/g;        # e acute
    $string =~ s/\xea/e/g;        # e circumflex
    $string =~ s/\xeb/e/g;        # e uml
    $string =~ s/\x01\x19/e/g;    # e ogonek
    $string =~ s/\xc4\x18/E/g;    # E ogonek

    $string =~ s/\xf2/o/g;        # o grave
    $string =~ s/\xf3/o/g;        # o acute
    $string =~ s/\xf4/o/g;        # o circumflex
    $string =~ s/\xf5/o/g;        # o tilde
    $string =~ s/\xf6/oe/g;       # o uml
    $string =~ s/\xf8/oe/g;       # o stroke

    $string =~ s/\xd3/o/g;        # o acute
    $string =~ s/\xf3/O/g;        # O acute

    $string =~ s/\xd2/O/g;        # O grave
    $string =~ s/\xd3/O/g;        # O acute
    $string =~ s/\xd4/O/g;        # O circumflex
    $string =~ s/\xd5/O/g;        # O tilde
    $string =~ s/\xd6/Oe/g;       # O uml

    $string =~ s/\xf9/u/g;        # u grave
    $string =~ s/\xfa/u/g;        # u acute
    $string =~ s/\xfb/u/g;        # u circumflex
    $string =~ s/\xfc/ue/g;       # u uml

    $string =~ s/\xd9/U/g;        # U grave
    $string =~ s/\xda/U/g;        # U acute
    $string =~ s/\xdb/U/g;        # U circumflex
    $string =~ s/\xdc/Ue/g;       # U uml

    $string =~ s/\xdf/ss/g;       # sharp s
    $string =~ s/\x01\x5b/s/g;    # s acute
    $string =~ s/\x01\x5a/S/g;    # S acute

    $string =~ s/\xf1/n/g;        # n tilde
    $string =~ s/\x01\x44/n/g;    # n acute
    $string =~ s/\x01\x43/N/g;    # N acute

    $string =~ s/\xfe/y/g;        # y acute
    $string =~ s/\xff/y/g;        # y uml

    $string =~ s/\xec/i/g;        # i grave
    $string =~ s/\xed/i/g;        # i acute
    $string =~ s/\xee/i/g;        # i circumflex
    $string =~ s/\xef/i/g;        # i uml

    $string =~ s/\x01\x42/l/g;    # l stroke
    $string =~ s/\x01\x41/L/g;    # L stroke

    $string =~ s/\x01\x7a/z/g;    # z acute
    $string =~ s/\x01\x79/Z/g;    # Z acute
    $string =~ s/\x01\x7c/z/g;    # z dot
    $string =~ s/\x01\x7b/Z/g;    # Z dot
  }

  return $string;
}

###############################################################################
sub HTML2TML {
  my ($this, $html) = @_;

  unless ($this->{convertor}) {
    require Foswiki::Plugins::WysiwygPlugin::HTML2TML;
    $this->{convertor} = new Foswiki::Plugins::WysiwygPlugin::HTML2TML();
  }

  # this is not _really_ html coming from html
  $html =~ s/^\s*$/<p><\/p>/gm;
  $html =~ s/<dt><\/dt>//gm; # clear error

  my $tml = $this->{convertor}->convert($html, {
      #very_clean   => 1,
    }
  );

  # some cleanup
  $tml =~ s/\n<br \/>/\n/gs;
  $tml =~ s/<br \/>\n/\n/gs;
  $tml =~ s/(<br \/>(<br \/>)+)/\n\n/g;

#  writeDebug("html:\n###\n$html\n###\n");

  # process images
  $tml =~ s/((?:\[\[.*\]\[)?<img ([^>]+)?\/>(?:\]\])?)/$this->extractImage($1)/ge;

  if ($tml =~ /(<img[^>]+>)/) {
    writeDebug("still an image found: ".$1);
  }

  #<img src="... " border="0" alt="" width="810" height="1044" /></a>
  #<a href="http://content.screencast.com/users/Kalyxo/folders/Jing/media/1145e440-c243-4377-b9fe-698ce6d0e9f5/00000286.png"><img src="http://content.screencast.com/users/Kalyxo/folders/Jing/media/1145e440-c243-4377-b9fe-698ce6d0e9f5/00000286.png" border="0" alt="" width="810" height="1044" /></a>


  return $tml;
}

###############################################################################
sub extractImage {
  my ($this, $text) = @_;

  #writeDebug("extractImage from $text");

  my @args = ();

  my $href;
  $href = $1 if $text =~ /^\[\[(.*?)\]\[/;
  push @args, 'type="plain"' unless defined $href;

  my $align;
  $align = $1 if $text =~ /align(left|right|center|none)/;
  push @args, 'align="'.$align.'"' if defined $align;


  my %record = (
    web => $this->{targetWeb},
    topic => $this->{targetTopic},
  );
  foreach my $attr (qw(width height title src)) {
    if ($text =~ /$attr=["']([^"']+)["']/) {
      my $val = $1;

      if ($attr eq 'src') {
        my $file = $val;
        $file =~ s/^.*\/([^\/]+)$/$1/;
        push @args, "\"$file\"";
        $record{url} = $val;
        $record{file} = $file;
      } else {
        push @args, "$attr=\"$val\"";
        $record{$attr} = $val;
      }
    }
  }

  push @{$this->{downloadables}}, \%record;

  my $result = "%IMAGE{".join(" ", @args)."}%";

  #writeDebug("result=$result");

  return $result;
}

###############################################################################
sub parseNode {
  my ($this, $dom) = @_;

  my @children = $dom->findnodes("./*");

  if (@children) {
    my $hash = {};

    foreach my $node (@children) { 
      my $type = $node->nodeType;
      next if $type eq XML_TEXT_NODE;

      my $key = $node->localname;
      my $prefix = $node->getPrefix;
      my $val = $this->parseNode($node);#recurse

      if ($prefix) {
        $hash->{$prefix} ||= {};
        _store_elem($hash->{$prefix}, $key, $val);
      } else {
        _store_elem($hash, $key, $val);
      }
    }

    return $hash;
  } else {
    return $dom->textContent;
  }
}

sub _store_elem {
  my ($hash, $key, $val) = @_;

  unless (ref($val)) {
    $val = Encode::encode($Foswiki::cfg{Site}{CharSet}, $val);
  }

  my $v = $hash->{$key};
  if (!defined $v) {
    $hash->{$key} = $val;
  } elsif (ref($v) eq 'ARRAY') {
    push @$v, $val;
  } else {
    $hash->{$key} = [$v, $val];
  }
}

###############################################################################
sub mirrorDownloadables {
  my ($this) = @_;

  my $imageCore = Foswiki::Plugins::ImagePlugin::getCore();

  foreach my $record (@{$this->{downloadables}}) {
    writeDebug("downloading $record->{url} to $record->{web}.$record->{topic} called $record->{file}");
    $imageCore->mirrorImage($record->{web}, $record->{topic}, $record->{url}, $record->{file}, 0)
      unless $this->{dry};
  }
}

1;
