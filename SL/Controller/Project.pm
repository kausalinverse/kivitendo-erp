package SL::Controller::Project;

use strict;

use parent qw(SL::Controller::Base);

use Clone qw(clone);

use SL::Controller::Helper::GetModels;
use SL::Controller::Helper::ParseFilter;
use SL::Controller::Helper::ReportGenerator;
use SL::CVar;
use SL::DB::Customer;
use SL::DB::DeliveryOrder;
use SL::DB::Invoice;
use SL::DB::Order;
use SL::DB::Project;
use SL::DB::ProjectType;
use SL::DB::ProjectStatus;
use SL::DB::PurchaseInvoice;
use SL::DB::ProjectType;
use SL::Helper::Flash;
use SL::Locale::String;

use Rose::Object::MakeMethods::Generic
(
 scalar => [ qw(project linked_records) ],
 'scalar --get_set_init' => [ qw(models customers project_types project_statuses) ],
);

__PACKAGE__->run_before('check_auth');
__PACKAGE__->run_before('load_project',        only => [ qw(edit update destroy) ]);

#
# actions
#

sub action_search {
  my ($self) = @_;

  my %params;

  $params{CUSTOM_VARIABLES}  = CVar->get_configs(module => 'Projects');
  ($params{CUSTOM_VARIABLES_FILTER_CODE}, $params{CUSTOM_VARIABLES_INCLUSION_CODE})
    = CVar->render_search_options(variables      => $params{CUSTOM_VARIABLES},
                                  include_prefix => 'l_',
                                  include_value  => 'Y');

  $self->render('project/search', %params);
}

sub action_list {
  my ($self) = @_;

  $self->make_filter_summary;

  my $projects = $self->models->get;

  $self->prepare_report;

  $self->report_generator_list_objects(report => $self->{report}, objects => $projects);
}

sub action_new {
  my ($self) = @_;

  $self->project(SL::DB::Project->new);
  $self->display_form(title    => $::locale->text('Create a new project'),
                      callback => $::form->{callback} || $self->url_for(action => 'new'));
}

sub action_edit {
  my ($self) = @_;

  $self->get_linked_records;
  $self->display_form(title    => $::locale->text('Edit project #1', $self->project->projectnumber),
                      callback => $::form->{callback} || $self->url_for(action => 'edit', id => $self->project->id));
}

sub action_create {
  my ($self) = @_;

  $self->project(SL::DB::Project->new);
  $self->create_or_update;
}

sub action_update {
  my ($self) = @_;
  $self->create_or_update;
}

sub action_destroy {
  my ($self) = @_;

  if (eval { $self->project->delete; 1; }) {
    flash_later('info',  $::locale->text('The project has been deleted.'));
  } else {
    flash_later('error', $::locale->text('The project is in use and cannot be deleted.'));
  }

  $self->redirect_to(action => 'search');
}

#
# filters
#

sub check_auth {
  $::auth->assert('project_edit');
}

#
# helpers
#

sub init_project_statuses { SL::DB::Manager::ProjectStatus->get_all_sorted }
sub init_project_types    { SL::DB::Manager::ProjectType->get_all_sorted   }

sub init_customers {
  my ($self)      = @_;
  my @customer_id = $self->project && $self->project->customer_id ? (id => $self->project->customer_id) : ();

  return SL::DB::Manager::Customer->get_all_sorted(where => [ or => [ obsolete => 0, obsolete => undef, @customer_id ]]);
}

sub display_form {
  my ($self, %params) = @_;

  $params{CUSTOM_VARIABLES}  = CVar->get_custom_variables(module => 'Projects', trans_id => $self->project->id);

  if ($params{keep_cvars}) {
    for my $cvar (@{ $params{CUSTOM_VARIABLES} }) {
      $cvar->{value} = $::form->{"cvar_$cvar->{name}"} if $::form->{"cvar_$cvar->{name}"};
    }
  }

  CVar->render_inputs(variables => $params{CUSTOM_VARIABLES}) if @{ $params{CUSTOM_VARIABLES} };

  $self->render('project/form', %params);
}

sub create_or_update {
  my $self   = shift;
  my $is_new = !$self->project->id;
  my $params = delete($::form->{project}) || { };

  delete $params->{id};
  $self->project->assign_attributes(%{ $params });

  my @errors = $self->project->validate;

  if (@errors) {
    flash('error', @errors);
    $self->display_form(title    => $is_new ? $::locale->text('Create a new project') : $::locale->text('Edit project'),
                        callback => $::form->{callback},
                        keep_cvars => 1);
    return;
  }

  $self->project->save;

  CVar->save_custom_variables(
    dbh          => $self->project->db->dbh,
    module       => 'Projects',
    trans_id     => $self->project->id,
    variables    => $::form,
    always_valid => 1,
  );

  flash_later('info', $is_new ? $::locale->text('The project has been created.') : $::locale->text('The project has been saved.'));

  $self->redirect_to($::form->{callback} || (action => 'search'));
}

sub load_project {
  my ($self) = @_;
  $self->project(SL::DB::Project->new(id => $::form->{id})->load);
}

sub get_linked_records {
  my ($self) = @_;

  $self->linked_records([
    map  { @{ $_ } }
    grep { $_      } (
      SL::DB::Manager::Order->          get_all(where => [ globalproject_id => $self->project->id ], with_objects => [ 'customer', 'vendor' ], sort_by => 'transdate ASC'),
      SL::DB::Manager::DeliveryOrder->  get_all(where => [ globalproject_id => $self->project->id ], with_objects => [ 'customer', 'vendor' ], sort_by => 'transdate ASC'),
      SL::DB::Manager::Invoice->        get_all(where => [ globalproject_id => $self->project->id ], with_objects => [ 'customer'           ], sort_by => 'transdate ASC'),
      SL::DB::Manager::PurchaseInvoice->get_all(where => [ globalproject_id => $self->project->id ], with_objects => [             'vendor' ], sort_by => 'transdate ASC'),
    )]);
}

sub prepare_report {
  my ($self)      = @_;

  my $callback    = $self->models->get_callback;

  my $report      = SL::ReportGenerator->new(\%::myconfig, $::form);
  $self->{report} = $report;

  my @columns     = qw(project_status customer projectnumber description active valid project_type);
  my @sortable    = qw(projectnumber description customer              project_type project_status);

  my %column_defs = (
    projectnumber => { obj_link => sub { $self->url_for(action => 'edit', id => $_[0]->id, callback => $callback) } },
    description   => { obj_link => sub { $self->url_for(action => 'edit', id => $_[0]->id, callback => $callback) } },
    project_type  => { sub  => sub { $_[0]->project_type->description } },
    project_status => { sub  => sub { $_[0]->project_status->description }, text => t8('Status') },
    customer      => { raw_data  => sub { $_[0]->customer_id ? $self->presenter->customer($_[0]->customer, display => 'table-cell', callback => $callback) : '' } },
    active        => { sub  => sub { $_[0]->active   ? $::locale->text('Active') : $::locale->text('Inactive') },
                       text => $::locale->text('Active') },
    valid         => { sub  => sub { $_[0]->valid    ? $::locale->text('Valid')  : $::locale->text('Invalid')  },
                       text => $::locale->text('Valid')  },
  );

  map { $column_defs{$_}->{text} ||= $::locale->text( $self->models->get_sort_spec->{$_}->{title} ) } keys %column_defs;

  if ( $report->{options}{output_format} =~ /^(pdf|csv)$/i ) {
    $self->models->disable_plugin('paginated');
  }
  $report->set_options(
    std_column_visibility => 1,
    controller_class      => 'Project',
    output_format         => 'HTML',
    raw_top_info_text     => $self->render('project/report_top', { output => 0 }),
    raw_bottom_info_text  => $self->render('project/report_bottom', { output => 0 }),
    title                 => $::locale->text('Projects'),
    allow_pdf_export      => 1,
    allow_csv_export      => 1,
  );
  $report->set_columns(%column_defs);
  $report->set_column_order(@columns);
  $report->set_export_options(qw(list filter));
  $report->set_options_from_form;
  $self->models->set_report_generator_sort_options(report => $report, sortable_columns => \@sortable);
  $report->set_options(
    raw_bottom_info_text  => $self->render('project/report_bottom', { output => 0 }),
  );
}

sub init_models {
  my ($self) = @_;

  SL::Controller::Helper::GetModels->new(
    controller => $self,
    sorted => {
      _default => {
        by    => 'projectnumber',
        dir   => 1,
      },
      customer      => t8('Customer'),
      description   => t8('Description'),
      projectnumber => t8('Project Number'),
      project_type  => t8('Project Type'),
    },
    with_objects => [ 'customer' ],
  );
}

sub make_filter_summary {
  my ($self) = @_;

  my $filter = $::form->{filter} || {};
  my @filter_strings;

  my @filters = (
    [ $filter->{"projectnumber:substr::ilike"},  t8('Project Number') ],
    [ $filter->{"description:substr::ilike"},    t8('Description')    ],
    [ $filter->{customer}{"name:substr::ilike"}, t8('Customer')       ],
    [ $filter->{"project_type_id"},              t8('Project Type'),    sub { SL::DB::Manager::ProjectType->find_by(id => $filter->{"project_type_id"})->description }   ],
    [ $filter->{"project_status_id"},            t8('Project Status'),  sub { SL::DB::Manager::ProjectStatus->find_by(id => $filter->{"project_status_id"})->description } ],
  );

  my @flags = (
    [ $filter->{active} eq 'active',    $::locale->text('Active')      ],
    [ $filter->{active} eq 'inactive',  $::locale->text('Inactive')    ],
    [ $filter->{valid}  eq 'valid',     $::locale->text('Valid')       ],
    [ $filter->{valid}  eq 'invalid',   $::locale->text('Invalid')     ],
    [ $filter->{orphaned},              $::locale->text('Orphaned')    ],
  );

  for (@flags) {
    push @filter_strings, "$_->[1]" if $_->[0];
  }
  for (@filters) {
    push @filter_strings, "$_->[1]: " . ($_->[2] ? $_->[2]->() : $_->[0]) if $_->[0];
  }

  $self->{filter_summary} = join ', ', @filter_strings;
}
1;
