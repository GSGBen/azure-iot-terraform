terraform {
  required_version = ">= 0.12"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.7.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "main" {
  name     = "azure-iot-tf"
  location = "Australia East"
}

resource "azurerm_iothub" "main" {
  name                = "azure-iot-tf-hub"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  sku {
    name     = "F1"
    capacity = "1"
  }
}

resource "azurerm_storage_account" "main" {
  name                     = "azureiottfstorage"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

}

resource "azurerm_storage_table" "main" {
  name                 = "azureiottfstoragetable"
  storage_account_name = azurerm_storage_account.main.name
}

resource "azurerm_iothub_consumer_group" "main" {
  name        = "azure-iot-tf-function-consumer"
  iothub_name = azurerm_iothub.main.name
  # I think this is the default one. Found in the example and in terraform.tfstate
  eventhub_endpoint_name = "events"
  resource_group_name    = azurerm_resource_group.main.name

  # try to work around this failing to create
  # https://github.com/hashicorp/terraform-provider-azurerm/issues/7444
  depends_on = [
    azurerm_iothub.main
  ]
}

resource "azurerm_service_plan" "function" {
  name                = "azure-iot-tf-function-plan"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Windows"
  sku_name            = "Y1"
}

resource "azurerm_windows_function_app" "main" {
  name                = "azure-iot-tf-function-app"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  storage_account_name       = azurerm_storage_account.main.name
  storage_account_access_key = azurerm_storage_account.main.primary_access_key
  service_plan_id            = azurerm_service_plan.function.id

  site_config {
    application_stack {
      node_version = "~14"
    }
  }

  app_settings = {
    # we can't get this directly, we have to construct it.
    # reverse engineered from the GUI-generated one and the .tfstate file.
    # in prod I'd filter for iothubowner, not index into an array.
    # join() is just to neaten up the long line
    "IOT_HUB_CONNECTION_STRING" = join("", [
      "Endpoint=${azurerm_iothub.main.event_hub_events_endpoint};",
      "SharedAccessKeyName=${azurerm_iothub.main.shared_access_policy[0].key_name};",
      "SharedAccessKey=${azurerm_iothub.main.shared_access_policy[0].primary_key};",
      "EntityPath=${azurerm_iothub.main.event_hub_events_path}"
    ])
    "STORAGE_CONNECTION_STRING" = azurerm_storage_account.main.primary_connection_string
  }
}

resource "azurerm_function_app_function" "main" {
  name            = "azure-iot-tf-function"
  function_app_id = azurerm_windows_function_app.main.id
  language        = "Javascript"

  file {
    name    = "index.js"
    content = file("../function/index.js")
  }

  config_json = jsonencode({
    "bindings" = [
      {
        "type"          = "eventHubTrigger"
        "name"          = "IoTHubMessages"
        "direction"     = "in"
        "eventHubName"  = azurerm_iothub.main.event_hub_events_path
        "connection"    = "IOT_HUB_CONNECTION_STRING"
        "cardinality"   = "many"
        "consumerGroup" = azurerm_iothub_consumer_group.main.name
      },
      {
        "name"       = "iothub"
        "direction"  = "out"
        "type"       = "table"
        "connection" = "STORAGE_CONNECTION_STRING"
        "tableName"  = azurerm_storage_table.main.name
      }
    ]
  })
}

resource "azurerm_service_plan" "webapp" {
  name                = "azure-iot-tf-webapp-plan"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = "F1"
}

resource "azurerm_linux_web_app" "main" {
  name                = "azureiottfwebapp"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_service_plan.webapp.location
  service_plan_id     = azurerm_service_plan.webapp.id

  site_config {
    application_stack {
      dotnet_version = "6.0"
    }
    app_command_line = "dotnet AzureIotTFWebApp.dll"
    always_on        = false
  }

  app_settings = {
    "AzureTablesConnectionString" = azurerm_storage_account.main.primary_connection_string
    "AzureTablesTableName"        = azurerm_storage_table.main.name
    "TZ"                          = "Australia/Melbourne"
    "WEBSITE_TIME_ZONE"           = "Australia/Melbourne"
  }
}

resource "azurerm_automation_account" "main" {
  name                = "azure-iot-tf-automation-account"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }
}

# could probs split this into two: table storage contributor, and overall reader
resource "azurerm_role_assignment" "storage_table_runbook_writer" {
  scope = azurerm_storage_account.main.id
  # read/write/delete
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}

resource "azurerm_automation_runbook" "retention" {
  name                    = "azure-iot-tf-runbook-retention"
  location                = azurerm_resource_group.main.location
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  description             = "remove temperature data older than x days"
  runbook_type            = "PowerShell"
  log_progress            = true
  log_verbose             = true

  content = file("../Runbooks/IotTablesRetention.ps1")
}

resource "azurerm_automation_module" "aztable" {
  name                    = "AzTable"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name

  module_link {
    uri = "https://devopsgallerystorage.blob.core.windows.net/packages/aztable.2.1.0.nupkg"
  }
}

resource "azurerm_automation_schedule" "retention" {
  name                    = "azure-iot-tf-automation-schedule-retention"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  frequency               = "Week"
  interval                = 1
  timezone                = "Australia/Sydney"
  # this needs to be at least 5 minutes in the future. in production I'd pass this in as a variable the first time
  # or find a way less gross way to do it. Surely there's something that's just "start now"
  start_time = "2022-11-06T11:35:00+10:00"
  week_days  = ["Monday"]
}

resource "azurerm_automation_job_schedule" "example" {
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  schedule_name           = azurerm_automation_schedule.retention.name
  runbook_name            = azurerm_automation_runbook.retention.name
}
